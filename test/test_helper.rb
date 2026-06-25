ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Minitest 6 dropped minitest/mock, so Object#stub is unavailable. Minimal
# equivalent: temporarily replace a (possibly private, possibly module/singleton)
# method with a fixed value OR a callable for the duration of the block, then
# restore the original afterwards even if the block raises.
module StubSupport
  def stub(name, value_or_callable, *)
    meta = singleton_class
    had_original = meta.method_defined?(name, false) || meta.private_method_defined?(name, false)
    original = meta.instance_method(name) if had_original
    meta.define_method(name) do |*args, **kwargs, &blk|
      value_or_callable.respond_to?(:call) ? value_or_callable.call(*args, **kwargs, &blk) : value_or_callable
    end
    yield
  ensure
    if had_original
      meta.define_method(name, original)
    else
      meta.send(:remove_method, name)
    end
  end
end
Object.include(StubSupport)

module ActiveSupport
  class TestCase
    # Run tests serially — no fixtures, each test builds the records it needs.
    fixtures :all
  end
end
