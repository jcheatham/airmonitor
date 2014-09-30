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
  begin
    last_refresh, last_error, errors = store.get(cache_key) || [Time.at(0), Time.at(0), {}]
  rescue Exception => e
    puts "Ignoring #{e}, cache probably poisoned, will just refetch everything"
  end

  # safety net in case the cache returns nils
  last_refresh ||= Time.at(0)
  last_error   ||= Time.at(0)
  errors       ||= {}

  puts "#{now} - #{last_refresh} = #{now - last_refresh}"
  current_errors = if ((now - last_refresh) > ERROR_REFRESH)
    current_errors = merge(errors, recent_error_notices(last_error))
    last_error = current_errors.values.max_by(&:most_recent_notice_at).most_recent_notice_at
    puts "Storing #{current_errors.count} errors with last_error at #{last_error}"
    store.set(cache_key, [now, last_error, current_errors], TTL_ERRORS)
    current_errors
  else
    errors
  end

  JSON.dump current_errors
end

def cache_key
  @cache_key ||= "air_monitor#{request.path}"
end

def merge(error_notices, new_error_notices)
  # NOTE TO SELF, this block is only evaluated when two keys collide and need a merge resolution
  error_notices.merge!(new_error_notices) do |key,oldval,newval|
    newval[:notices] = Array(newval[:notices])
    newval[:notices].concat(oldval[:notices]).sort_by!{|a| a[:created_at] }.reverse!.uniq!{|b| b[:id] }
    newval[:notices].slice!(30, newval[:notices].length)
    newval
  end
  cutoff = Time.now - 12*60*60
  error_notices.select do |k,v|
    v[:notices].select!{|n| n.created_at > cutoff }
    v[:frequency] = frequency(v[:notices]) || rough_frequency(v)
    v[:notices].length > 0 || v[:frequency] > 1
  end
end

def frequency(notices)
  return if notices.length < 2
  w = 0.5
  period = notices.each_cons(2).map{|a,b| a[:created_at] - b[:created_at] }.reverse.reduce(nil){|p,d| w*d + (1-w)*(p||d)}
  period = w * ([Time.now, notices.map{|n|n[:created_at]}.max].max - notices.first[:created_at]) + (1-w) * period
  3600.0/period
end

def rough_frequency(error)
  range = error[:most_recent_notice_at] - error[:created_at]
  range = 1 if range < 1
  (error[:total_notices] || 1) / range
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
  @store ||= Dalli::Client.new
end

def recent_error_notices(since)
  errors = airbrake.errors(:page => 1, :project_id => params[:project]) || []
  puts "Selecting errors since #{since}"
  errors.select!{|e| e[:most_recent_notice_at] > since }
  Parallel.map(errors, :in_threads => 10) do |error|
    begin
      error.delete(:updated_at) # for some reason we're getting '0001-01-01 00:00:00 UTC' in here which causes a marshal error
      error[:id] = error[:id].to_s
      error[:notices] = airbrake.notices(error[:id], :pages => 1, :raw => true).compact
      error[:notices].each{|n| n[:id] = n[:id].to_s ; n[:project_id] = n[:project_id].to_s }
    rescue Faraday::Error::ParsingError => e
      puts "Ignoring notices for #{error}, got 500 from http://#{airbrake.account}.airbrake.io/errors/#{error[:id]}"
    rescue Exception => e
      puts "Ignoring exception #{e}"
    end
    error
  end.compact.each_with_object({}){|e,h|h[e.id]=e}
end

