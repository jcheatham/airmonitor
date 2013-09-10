require 'bundler/setup'
Bundler.require

ENV["MEMCACHE_SERVERS"] = ENV["MEMCACHIER_SERVERS"] if ENV["MEMCACHIER_SERVERS"]
ENV["MEMCACHE_USERNAME"] = ENV["MEMCACHIER_USERNAME"] if ENV["MEMCACHIER_USERNAME"]
ENV["MEMCACHE_PASSWORD"] = ENV["MEMCACHIER_PASSWORD"] if ENV["MEMCACHIER_PASSWORD"]

TTL_PROJECTS = 60*60
TTL_ERRORS = 24*60*60

set :views, 'views'

use Rack::SSL if production?

get '/' do
  erb :index
end

get '/projects/:subdomain/:token.json' do
  store_key = "air_monitor.projects.#{params[:subdomain]}.#{params[:token]}"
  store.fetch(store_key, TTL_PROJECTS) do
    json airbrake(params[:subdomain], params[:token]).projects
  end
end

def json(something)
  JSON.dump(something)
end

def airbrake(subdomain = nil, token = nil)
  @airbrake ||= AirbrakeAPI::Client.new(:account => subdomain, :auth_token => token, :secure => true)
end

def store
  @store ||= Dalli::Client.new(nil)
end
