require "test_helper"

class PushSubscriptionsTest < ActionDispatch::IntegrationTest
  test "registers a subscription" do
    assert_difference -> { PushSubscription.count }, 1 do
      post push_subscriptions_path, params: {
        subscription: { endpoint: "https://push/abc", keys: { p256dh: "pk", auth: "ak" } }
      }, as: :json
    end
    assert_response :success
  end

  test "unregisters by endpoint" do
    PushSubscription.create!(endpoint: "https://push/abc", p256dh: "pk", auth: "ak")
    assert_difference -> { PushSubscription.count }, -1 do
      delete push_subscriptions_path, params: { endpoint: "https://push/abc" }, as: :json
    end
  end
end
