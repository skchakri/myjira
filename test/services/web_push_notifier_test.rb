require "test_helper"

class WebPushNotifierTest < ActiveSupport::TestCase
  setup do
    @project = Project.create!(name: "P", slug: "p-#{SecureRandom.hex(3)}", repo_path: "/tmp/p")
    @task = @project.tasks.create!(title: "Approve me", item_type: "feature", board_state: "waiting",
                                   wait_reason: "awaiting_approval", plan: "p")
    PushSubscription.create!(endpoint: "https://push/1", p256dh: "p", auth: "a")
    PushSubscription.create!(endpoint: "https://push/2", p256dh: "p", auth: "a")
  end

  test "sends to every subscription when VAPID is configured" do
    sent = 0
    WebPushNotifier.stub(:vapid_configured?, true) do
      WebPush.stub(:payload_send, ->(**) { sent += 1 }) do
        WebPushNotifier.notify_waiting(@task)
      end
    end
    assert_equal 2, sent
  end

  test "prunes a subscription the push service reports as expired" do
    WebPushNotifier.stub(:vapid_configured?, true) do
      expired = WebPush::ExpiredSubscription.allocate # bare instance; skip the response-bound initializer
      WebPush.stub(:payload_send, ->(**) { raise expired }) do
        WebPushNotifier.notify_waiting(@task)
      end
    end
    assert_equal 0, PushSubscription.count, "expired subscriptions are deleted"
  end

  test "is a no-op when VAPID is not configured" do
    called = false
    WebPushNotifier.stub(:vapid_configured?, false) do
      WebPush.stub(:payload_send, ->(**) { called = true }) do
        WebPushNotifier.notify_waiting(@task)
      end
    end
    assert_not called
  end
end
