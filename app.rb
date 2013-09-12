require 'bundler/setup'
Bundler.require
require 'hashie'
require 'logger'

ENV["MEMCACHE_SERVERS"]  = ENV["MEMCACHIER_SERVERS"]  if ENV["MEMCACHIER_SERVERS"]
ENV["MEMCACHE_USERNAME"] = ENV["MEMCACHIER_USERNAME"] if ENV["MEMCACHIER_USERNAME"]
ENV["MEMCACHE_PASSWORD"] = ENV["MEMCACHIER_PASSWORD"] if ENV["MEMCACHIER_PASSWORD"]

TTL_PROJECTS = 60*60
TTL_ERRORS = 24*60*60
ERROR_REFRESH = 30

set :logging, true
set :dump_errors, true
set :raise_errors, true

use Rack::SSL if production?

get '/' do
  puts "params #{params}"
  if params[:subdomain] && params[:token]
    redirect "/monitor/#{params[:subdomain]}/#{params[:token]}"
  else
    erb :index
  end
end

get '/monitor/:subdomain/:token' do
  erb :monitor, :projects => projects
end

get '/projects/:subdomain/:token.json' do
  JSON.dump projects
end

get '/errors/:subdomain/:token/:project.json' do
  now = Time.now
  old_errors, since = store.get(cache_key) || [{}, Time.at(0)]
  current_errors = if ((now - since) > ERROR_REFRESH)
    current_errors = merge(old_errors, recent_error_notices(since))
    store.set(cache_key, [current_errors, now], TTL_ERRORS)
    current_errors
  else
    old_errors
  end

  JSON.dump current_errors
end

def cache_key
  @cache_key ||= "air_monitor#{request.path}"
end

def merge(notices, new_notices)
  notices.merge!(new_notices) do |key,oldval,newval|
    newval[:notices].concat(oldval[:notices]).sort_by!{|a| a[:created_at] }.reverse!.uniq!{|b| b[:id] }
    newval
  end
  notices.each{|k,v| v[:frequency] = frequency(v[:notices]) || rough_frequency(v) }
  notices
end

def frequency(notices)
  return if notices.length < 2
  w = 0.5
  period = notices.each_cons(2).map{|a,b| a[:created_at] - b[:created_at] }.reverse.reduce(nil){|p,d| w*d + (1-w)*(p||d)}
  period = w * (Time.now - notices.first[:created_at]) + (1-w) * period
  3600.0/period
end

def rough_frequency(error)
  error[:total_notices] / (error[:most_recent_notice_at] - error[:created_at])
end

def airbrake
  @airbrake ||= AirbrakeAPI::Client.new(:account => params[:subdomain], :auth_token => params[:token], :secure => true)
end

def projects
  store.fetch(cache_key, TTL_PROJECTS) do
    airbrake.projects
  end
end

def store
  @store ||= if ENV["MEMCACHIER_SERVERS"]
    Dalli::Client.new(ENV["MEMCACHIER_SERVERS"].split(","), {:username => ENV["MEMCACHIER_USERNAME"], :password => ENV["MEMCACHIER_PASSWORD"]})
  else
    Dalli::Client.new(nil)
  end
end

def recent_error_notices(since)
  errors = airbrake.errors(:page => 1, :project_id => params[:project]) || []
  errors.select!{|e| e[:most_recent_notice_at] > since }
  Parallel.map(errors, :in_threads => 10) do |error|
    begin
      error[:notices] = airbrake.notices(error[:id], :pages => 1, :raw => true).compact
    rescue Faraday::Error::ParsingError => e
      puts "Ignoring notices for #{error}, got 500 from http://#{airbrake.account}.airbrake.io/errors/#{error[:id]}"
    rescue Exception => e
      puts "Ignoring exception #{e}"
    end
    error
  end.compact.reduce({}){|h,e|h[e.id]=e;h}
end

