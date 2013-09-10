require 'spec_helper'

describe 'App' do
  include Rack::Test::Methods

  def app
    Sinatra::Application.new
  end

  it "gets /" do
    get '/'
    last_response.body.should include('<div')
  end
end
