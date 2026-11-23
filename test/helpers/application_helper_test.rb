require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "safe_external_url keeps http and https links" do
    assert_equal "https://github.com/o/r/pull/1", safe_external_url("https://github.com/o/r/pull/1")
    assert_equal "http://jira.local/browse/X-1", safe_external_url("http://jira.local/browse/X-1")
  end

  test "safe_external_url rejects script and relative urls" do
    assert_nil safe_external_url("javascript:alert(1)")
    assert_nil safe_external_url("data:text/html,hi")
    assert_nil safe_external_url("/relative")
    assert_nil safe_external_url(nil)
    assert_nil safe_external_url("http://")
  end
end
