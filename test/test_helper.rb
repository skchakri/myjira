ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests serially — no fixtures, each test builds the records it needs.
    fixtures :all
  end
end
