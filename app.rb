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
DEFAULT_TIME = Time.at(0).freeze
IP_WHITELIST = (ENV["IP_WHITELIST"] || "127.0.0.1").split(" ")
W = 0.5
ONE_MINUS_W = 1.0 - W

set :logging, true
set :dump_errors, true
set :raise_errors, true

use Rack::SSL if production?
use Rack::IpFilter, IpFilter::WhiteList.new(IP_WHITELIST), '/'
use Rack::Session::Cookie, :secret => ENV["COOKIE_SECRET"]
use Rack::Deflater

use OmniAuth::Builder do
  provider :google_oauth2, ENV["GOOGLE_OAUTH_CLIENT_ID"], ENV["GOOGLE_OAUTH_CLIENT_SECRET"], {:name => "google", :scope => "email"}
end

before /^(?!\/(auth|tester|fail))/ do
  puts "#{now.iso8601} request: #{request.inspect}"
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
  cache.flush_all.to_s
end

get '/errors.json' do
  project_ids = projects.map(&:id) & params[:projects]
  JSON.dump update_projects(project_ids).flatten.compact
end

get '/blurb.json' do
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
  puts "P#{project_id} - error update request"
  airbrake.errors(:page => 1, :project_id => project_id)
rescue Faraday::Error::ParsingError => e
  puts "P#{project_id} - Bad response for http://#{airbrake.account}.airbrake.io/projects/#{project_id} - #{e}"
rescue StandardError => e
  puts "P#{project_id} - Ignoring exception #{e}"
end

def sanitized_airbrake_errors(project_id)
  Array(airbrake_errors(project_id)).compact.map do |raw|
    {:id            => raw[:id].to_s,
     :project_id    => raw[:project_id].to_s,
     :created_at    => raw[:created_at],
     :env           => raw[:rails_env],
     :error_class   => raw[:error_class],
     :count         => raw[:notices_count],
     :most_recent   => raw[:most_recent_notice_at],
     :message       => raw[:error_message].to_s
    }
  end
end

def airbrake_error_notices(error_id)
  puts "E#{error_id} - notice update request"
  airbrake.notices(error_id, :pages => 1, :raw => true)
rescue Faraday::Error::ParsingError => e
  puts "E#{error_id} - Bad response for http://#{airbrake.account}.airbrake.io/errors/#{error_id} - #{e}"
rescue StandardError => e
  puts "E#{error_id} - Ignoring exception #{e}"
end

def sanitized_airbrake_error_notices(error_id)
  Array(airbrake_error_notices(error_id)).compact.map do |raw|
    {:uuid       => raw[:uuid],
     :created_at => raw[:created_at],
     :message    => raw[:error_message].to_s
    }
  end
end

def update_projects(project_ids)
  Parallel.map(project_ids, :in_threads => 10) do |project_id|
    update_project(project_id)
  end
end

def update_project(project_id)
  errors = if now > (get_last_refresh(project_id) + REFRESH_LIMIT)
    set_last_refresh(project_id, now)
    set_last_project_errors(project_id, sanitized_airbrake_errors(project_id))
  else
    get_last_project_errors(project_id)
  end

  Parallel.map(errors, :in_threads => 10) do |error|
    update_error(get_error(error[:id]), error)
  end
end

def update_error(error, new_data)
  if new_data[:most_recent] > (error[:most_recent] || DEFAULT_TIME)
    error.merge!(new_data)
    error[:notices] = Array(error[:notices]) + sanitized_airbrake_error_notices(error[:id])
    error[:notices].sort_by!{|a| a[:created_at] }.reverse!.uniq!{|b| b[:uuid] }
    error[:notices].slice!(30, error[:notices].length)
  end
  error[:frequency] = error_frequency(error, now)
  set_error(error)
end

def error_frequency(error, now)
  if error[:notices].length < 2
    (error[:count] || 1) / [error[:most_recent] - error[:created_at], 1.0].max
  else
    events = error[:notices].map{|n| n[:created_at] }.sort
    range_average = ([now, events.last].max - events.first)/events.count
    weighted_interval_average = events.each_cons(2).map{|a,b| b - a }.reduce(nil){|p,d| W * d + ONE_MINUS_W * (p||d)}
    3600.0 / (W * range_average + ONE_MINUS_W * weighted_interval_average)
  end
end

def projects
  cache.fetch("air_monitor.projects.#{airbrake.account}", TTL_PROJECTS) do
    airbrake.projects.sort_by { |project| project.name.downcase }
  end
end

def project_settings
  @project_settings ||= Marshal.load(Base64.decode64(ENV["PROJECT_SETTINGS"]))
end

def now
  @now ||= Time.now
end

def cache
  @cache ||= Dalli::Client.new
end

def cache_get(key, default=nil)
  cache.get(key) || default
rescue => e
  puts "Ignoring #{e}, cache probably poisoned, will just refetch everything"
  default
end

def get_error(error_id)
  cache_get("air_monitor.error.#{error_id}", {})
end

def set_error(error)
  cache.set("air_monitor.error.#{error[:id]}", error, TTL_ERRORS)
  error
end

def get_last_refresh(project_id)
  cache_get("air_monitor.refreshes.#{project_id}", DEFAULT_TIME)
end

def set_last_refresh(project_id, time)
  cache.set("air_monitor.refreshes.#{project_id}", time, TTL_ERRORS)
end

def get_last_project_errors(project_id)
  errors = cache_get("air_monitor.project_errors.#{project_id}", [])
end

def set_last_project_errors(project_id, errors)
  cache.set("air_monitor.project_errors.#{project_id}", errors, TTL_ERRORS)
  errors
end
