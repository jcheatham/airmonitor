require 'bundler/setup'
Bundler.require

set :views, 'views'

use Rack::SSL if production?

get '/' do
  erb :index
end

get '/projects/:subdomain/:token.json' do
  json airbrake(params[:subdomain], params[:token]).projects
end

def json(something)
  JSON.dump(something)
end

def airbrake(subdomain = nil, token = nil)
  @airbrake ||= AirbrakeAPI::Client.new(:account => subdomain, :auth_token => token, :secure => true)
end
