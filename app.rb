require 'bundler/setup'
Bundler.require
require 'hashie'
require 'logger'

ENV["MEMCACHE_SERVERS"]  = ENV["MEMCACHIER_SERVERS"]  if ENV["MEMCACHIER_SERVERS"]
ENV["MEMCACHE_USERNAME"] = ENV["MEMCACHIER_USERNAME"] if ENV["MEMCACHIER_USERNAME"]
ENV["MEMCACHE_PASSWORD"] = ENV["MEMCACHIER_PASSWORD"] if ENV["MEMCACHIER_PASSWORD"]
File.exists?(".env") && File.read(".env").each_line do |line|
  line.partition("#").first.strip.split("=",2).tap{ |k,v| ENV[k] = v }
end

TTL_PROJECTS = 60*60
TTL_ERRORS = 24*60*60
REFRESH_LIMIT = 30
DEFAULT_TIME = Time.at(0)

set :logging, true
set :dump_errors, true
set :raise_errors, true

use Rack::SSL if production?
use Rack::Deflater
use Rack::Session::Cookie, :secret => ENV["COOKIE_SECRET"]
use OmniAuth::Builder do
  provider :google_oauth2, ENV["GOOGLE_OAUTH_CLIENT_ID"], ENV["GOOGLE_OAUTH_CLIENT_SECRET"], {:name => "google", :scope => "email"}
end

before /^(?!\/(auth|tester))/ do
  redirect '/auth/google' unless session[:authorized_domain]
end

get '/auth/:provider/callback' do
  authorize!(omniauth_domain(request.env['omniauth.auth']))
end

post '/auth/:provider/callback' do
  authorize!(omniauth_domain(request.env['omniauth.auth']))
end

get '/fail' do
  "fail"
end

get '/' do
  erb :index, :locals => {:projects => projects, :account => project_settings[session[:authorized_domain]][0], :selected_projects => Array(params[:projects])}
end

get '/flush' do
  store.flush_all.to_s
end

get '/errors.json' do
  now = Time.now
  project_ids = projects.map(&:id) & params[:projects]

  Parallel.each(project_ids, :in_threads => 10) do |project_id|
    next unless (data[:last_refresh][project_id] + REFRESH_LIMIT) < now
    data[:last_refresh][project_id] = now
    most_recent_update = project_update = data[:last_update][project_id]
    Parallel.each(Array(airbrake_errors(project_id)).compact, :in_threads => 10) do |error|
      next unless error[:most_recent_notice_at] > project_update
      most_recent_update = [error[:most_recent_notice_at], most_recent_update].max
      error.delete(:updated_at) # airbrake is sending us '0001-01-01 00:00:00 UTC' which causes a marshal error
      error[:id] = error[:id].to_s # convert IDs to string or risk javascript number precision errors
      error[:project_id] = error[:project_id].to_s
      error[:notices] = Array(airbrake_error_notices(error[:id])).compact
      error[:notices].each{|n| n[:id] = n[:id].to_s ; n.delete(:project_id) }
      data[:errors].merge!(error[:id] => error) do |key,oldval,newval|
        newval[:notices].concat(oldval[:notices]).sort_by!{|a| a[:created_at] }.reverse!.uniq!{|b| b[:id] }
        newval[:notices].slice!(30, newval[:notices].length)
        newval
      end
    end
    data[:last_update][project_id] = most_recent_update
  end

  # cull old/inconsequential errors prior to saving to cache
  w = 0.5
  w1 = 1 - w
  data[:errors].select! do |error_id,error|
    error[:frequency] = if error[:notices].length < 2
      (error[:total_notices] || 1) / [error[:most_recent_notice_at] - error[:created_at], 1.0].max
    else
      events = error[:notices].map{|notice| notice[:created_at] }.sort
      range_average = ([now, events.last].max - events.first)/events.count
      weighted_interval_average = events.each_cons(2).map{|a,b| b - a }.reduce(nil){|p,d| w * d + w1 * (p||d)}
      3600.0 / (w * range_average + w1 * weighted_interval_average)
    end
    error[:frequency] > 1.0
  end

  cache_data!

  # cull errors belonging to projects that weren't requested
  data[:errors].select! do |error_id,error|
    project_ids.include?(error[:project_id])
  end

  JSON.dump data[:errors]
end



def omniauth_domain(payload)
  payload && payload[:info] && payload[:info][:email].to_s.split("@",2)[1].to_s.downcase
end

def authorize!(domain)
  redirect '/fail' unless project_settings[domain]
  session[:authorized_domain] = domain
  redirect '/'
end

def airbrake
  @airbrake ||= begin
    account, token = project_settings[session[:authorized_domain]]
    AirbrakeAPI::Client.new(:secure => true, :account => account, :auth_token => token)
  end
end

def airbrake_errors(project_id)
  airbrake.errors(:page => 1, :project_id => project_id)
rescue Faraday::Error::ParsingError => e
  puts "Bad response for http://#{airbrake.account}.airbrake.io/projects/#{project_id} - #{e}"
rescue Exception => e
  puts "Ignoring exception #{e} for #{project_id}"
end

def airbrake_error_notices(error_id)
  airbrake.notices(error_id, :pages => 1, :raw => true)
rescue Faraday::Error::ParsingError => e
  puts "Bad response for http://#{airbrake.account}.airbrake.io/errors/#{error_id} - #{e}"
rescue Exception => e
  puts "Ignoring exception #{e} for #{error_id}"
end

def projects
  store.fetch("air_monitor.projects.#{airbrake.account}", TTL_PROJECTS) do
    airbrake.projects.sort_by { |project| project.name.downcase }
  end
end

def project_settings
  @project_settings ||= Marshal.load(Base64.decode64(ENV["PROJECT_SETTINGS"]))
end

def store
  @store ||= Dalli::Client.new
end

def cache_data!
  store.set("air_monitor.data.#{airbrake.account}", data, TTL_ERRORS)
end

def data
  @data ||= begin
    cached_data = begin
      store.get("air_monitor.data.#{airbrake.account}")
    rescue Exception => e
      puts "Ignoring #{e}, cache probably poisoned, will just refetch everything"
    end || {}
    cached_data[:last_refresh] ||= Hash.new(DEFAULT_TIME)
    cached_data[:last_update] ||= Hash.new(DEFAULT_TIME)
    cached_data[:errors] ||= {}
    cached_data
  end
end
