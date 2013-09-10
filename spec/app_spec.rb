require 'spec_helper'

describe 'App' do
  include Rack::Test::Methods

  let(:config) { YAML.load_file('spec/config.yml') }
  let(:credentials) { "#{config.fetch('subdomain')}/#{config.fetch('auth_token')}" }
  let(:store) { EmptyStore.new }

  def app
    Sinatra::Application.new
  end

  it "gets /" do
    get '/'
    last_response.body.should include('<div')
  end

  it "fetches project" do
    get "/projects/#{credentials}.json"
    last_response.body.should include config.fetch('expected_project_name')
  end

  it "fetches errors" do
    get "/errors/#{credentials}/#{config.fetch('expected_project_id')}.json"
    response = JSON.parse(last_response.body)
    response.size.should >= 1
    response.first.first["error_class"].should_not == nil
  end
end
