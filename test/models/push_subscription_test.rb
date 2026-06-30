require "test_helper"

class PushSubscriptionTest < ActiveSupport::TestCase
  test "requires endpoint, p256dh, auth and a unique endpoint" do
    attrs = { endpoint: "https://push/1", p256dh: "p", auth: "a" }
    assert PushSubscription.create!(attrs)
    dup = PushSubscription.new(attrs)
    assert_not dup.valid?
    assert_not PushSubscription.new(endpoint: "", p256dh: "p", auth: "a").valid?
  end

  test "upsert_from! creates then updates by endpoint" do
    s1 = PushSubscription.upsert_from!(endpoint: "https://push/x", p256dh: "p1", auth: "a1", user_agent: "ua")
    s2 = PushSubscription.upsert_from!(endpoint: "https://push/x", p256dh: "p2", auth: "a2", user_agent: "ua")
    assert_equal s1.id, s2.id, "same endpoint updates the same row"
    assert_equal "p2", s2.reload.p256dh
  end
end
