require 'spec_helper'

describe 'App' do
  include Rack::Test::Methods

  let(:config) { YAML.load_file('spec/config.yml') }
  let(:credentials) { "#{config.fetch('subdomain')}/#{config.fetch('auth_token')}" }

  def app
    Sinatra::Application.new
  end

  it "gets /" do
    get '/'
    last_response.body.should include('<div')
  end

  it "fetches project" do
    get "/projects/#{credentials}.json"
    last_response.body.should include config.fetch('expected_project')
  end
end
