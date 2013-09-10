require 'sinatra'

set :views, 'views'

use Rack::SSL if production?

get '/' do
  erb :index
end
