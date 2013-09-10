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

get '/errors/:subdomain/:token/:project.json' do
  errors = airbrake(params[:subdomain], params[:token]).errors(:page => 1, :project_id => params[:project]) || []
  json recent_error_notices(errors, Time.at(0))
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

def recent_error_notices(errors, since)
  recent_errors = errors.select{|e| e.most_recent_notice_at > since }
  Parallel.map(recent_errors, :in_threads => 10) do |error|
    begin
      pages = 1
      notices = airbrake.notices(error.id, :pages => pages, :raw => true).compact
      [error, notices]
    rescue Faraday::Error::ParsingError => e
      Rails.logger.error "Ignoring notices for #{error}, got 500 from http://zendesk.airbrake.io/errors/#{error.id}"
      [error, []]
    rescue Exception => e
      Rails.logger.error "Ignoring exception #{e}"
      [error, []]
    end
  end.compact
end

