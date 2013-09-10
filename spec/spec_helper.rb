require_relative '../app'

require 'rack/test'
require 'yaml'

class EmptyStore
  def fetch(*args)
    yield
  end
end
