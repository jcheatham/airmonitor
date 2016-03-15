require 'bundler/setup'
Bundler.require
require 'logger'
require 'open-uri'
require 'net/http'
require 'net/https'

File.exists?(".env") && File.read(".env").each_line do |line|
  next if line.start_with?("#")
  line.split("#").first.strip.split("=",2).tap{ |k,v| ENV[k] = v }
end

ENV["MEMCACHE_SERVERS"]  = ENV["MEMCACHIER_SERVERS"]  if ENV["MEMCACHIER_SERVERS"]
ENV["MEMCACHE_USERNAME"] = ENV["MEMCACHIER_USERNAME"] if ENV["MEMCACHIER_USERNAME"]
ENV["MEMCACHE_PASSWORD"] = ENV["MEMCACHIER_PASSWORD"] if ENV["MEMCACHIER_PASSWORD"]

TTL_PROJECTS = 60*60
TTL_ERRORS = 24*60*60
REFRESH_LIMIT = 30
DEFAULT_TIME = Time.at(0).freeze
IP_WHITELIST = (ENV["IP_WHITELIST"] || "127.0.0.1 ::1").split(" ")
PROJECT_THREADS = (ENV["PROJECT_THREADS"] || 10).to_i
ERROR_THREADS = (ENV["ERROR_THREADS"] || 10).to_i
W = 0.5
ONE_MINUS_W = 1.0 - W
API_BASE_URL = "https://airbrake.io/api/v4"

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
  @account, @token = project_settings[session[:authorized_domain]]
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
  erb :index, :locals => {:projects => airbrake_projects, :account => @account, :selected_projects => Array(params[:projects])}
end

get '/flush' do
  cache.flush_all.to_s
end

get '/projects.json' do
  JSON.dump airbrake_projects
end

get '/errors.json' do
  project_ids = airbrake_projects.map{|p| p[:id] } & params[:projects]
  JSON.dump update_projects(project_ids).flatten.compact
end

def omniauth_domain(payload)
  payload && payload[:info] && payload[:info][:email].to_s.split("@",2)[1].to_s.downcase
end

def authorize!(domain)
  redirect '/fail' unless project_settings[domain]
  session[:authorized_domain] = domain
  redirect '/'
end

def airbrake_projects
  cache.fetch("air_monitor.projects.#{@account}", TTL_PROJECTS) do
    response = make_request("#{API_BASE_URL}/projects?key=#{@token}")
    case response.code.to_i
    when 200..299
      JSON.parse(response.body)["projects"].compact.map do |raw|
        {:id   => raw["id"].to_s,
         :name => raw["name"]
        }
      end.sort_by{|p| p[:name].to_s.downcase }
    else
      puts "ERROR - Bad response for #{API_BASE_URL}/projects - #{response.code} - #{response.message}"
    end
  end
end

def airbrake_errors(project_id)
  response = make_request("#{API_BASE_URL}/projects/#{project_id}/groups?key=#{@token}")
  case response.code.to_i
  when 200..299
    JSON.parse(response.body)["groups"].compact.map do |raw|
      {
        :id            => raw["id"].to_s,
        :project_id    => raw["projectId"].to_s,
        :env           => raw["context"]["environment"],
        :count         => raw["noticeCount"],
        :created_at    => Time.parse(raw["createdAt"]),
        :most_recent   => Time.parse(raw["lastNoticeAt"]),
        :message       => raw["errors"][0]["message"].to_s
      }
    end
  else
    puts "ERROR - Bad response for #{API_BASE_URL}/projects/#{project_id}/groups - #{response.code} - #{response.message}"
  end
end

def airbrake_error_notices(project_id, error_id)
  response = make_request("#{API_BASE_URL}/projects/#{project_id}/groups/#{error_id}/notices?key=#{@token}")
  case response.code.to_i
  when 200..299
    JSON.parse(response.body)["notices"].compact.map do |raw|
      {
        :id            => raw["id"].to_s,
        :created_at    => Time.parse(raw["createdAt"]),
        :message       => raw["errors"][0]["message"].to_s,
        :backtrace     => (raw["errors"].first['backtrace'] || []).
          map { |l| "#{l["file"]}:#{l["line"]}".sub("[PROJECT_ROOT]/", "") }.
          reject { |l| l.start_with?("[GEM_ROOT]/gems/newrelic_rpm-") }[0..100],
        :params        => raw["params"]
      }
    end
  else
    puts "ERROR - Bad response for #{API_BASE_URL}/projects/#{project_id}/groups/#{error_id}/notices - #{response.code} - #{response.message}"
  end
end

def update_projects(project_ids)
  Parallel.map(project_ids, :in_threads => PROJECT_THREADS) do |project_id|
    update_project(project_id)
  end
end

def update_project(project_id)
  errors = if now > (get_last_refresh(project_id) + REFRESH_LIMIT)
    set_last_refresh(project_id, now)
    set_last_project_errors(project_id, airbrake_errors(project_id))
  else
    get_last_project_errors(project_id)
  end

  Parallel.map(errors, :in_threads => ERROR_THREADS) do |error|
    update_error(project_id, get_error(error[:id]), error)
  end
end

def update_error(project_id, error, new_data)
  if new_data[:most_recent] > (error[:most_recent] || DEFAULT_TIME)
    error.merge!(new_data)
    error[:notices] = Array(error[:notices]) + airbrake_error_notices(project_id, error[:id])
    error[:notices].sort_by!{|a| a[:created_at] }.reverse!.uniq!{|b| b[:id] }
    error[:notices].slice!(30, error[:notices].length)
  end
  error[:backtraces] = error[:notices].map{ |n| n[:backtrace] }.compact.
    group_by { |b| b }.
    sort_by { |_,bs| bs.size }.
    map { |b, bs| {backtrace: b.join("\n"), count: bs.size} }
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
  cache_get("air_monitor.project_errors.#{project_id}", [])
end

def set_last_project_errors(project_id, errors)
  cache.set("air_monitor.project_errors.#{project_id}", errors, TTL_ERRORS)
  errors
end

def make_request(url)
  # stolen from https://github.com/bf4/airbrake_client/blob/master/airbrake_client.rb
  uri = URI(url)
  http = Net::HTTP.new(uri.host, uri.port)
  if http.use_ssl = (uri.scheme == 'https')
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
  end
  request = Net::HTTP::Get.new(uri.request_uri)
  http.request(request)
end
