# Sends a Web Push notification to every registered browser when a board item
# parks waiting on the human. Best-effort: no-op without VAPID keys, prunes dead
# subscriptions, and never raises into the caller (the blink + /approvals inbox are
# the reliable surfaces).
class WebPushNotifier
  def self.notify_waiting(task)
    return unless vapid_configured?

    title = task.needs_input? ? "Needs your input" : "Plan awaiting approval"
    body  = "#{task.project.name}: #{task.title}"
    url   = "#{base_url}/projects/#{task.project.slug}/tasks/#{task.id}"
    message = { title: title, body: body, url: url }.to_json

    PushSubscription.find_each do |sub|
      WebPush.payload_send(
        message: message, endpoint: sub.endpoint, p256dh: sub.p256dh, auth: sub.auth,
        vapid: vapid, ttl: 600
      )
    rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
      sub.destroy
    rescue WebPush::Error => e
      Rails.logger.warn("[webpush] #{sub.endpoint}: #{e.class}: #{e.message}")
    end
  rescue StandardError => e
    Rails.logger.warn("[webpush] notify_waiting failed: #{e.class}: #{e.message}")
  end

  def self.vapid
    { subject: ENV.fetch("VAPID_SUBJECT", "mailto:admin@myjira.local"),
      public_key: ENV["VAPID_PUBLIC_KEY"].to_s, private_key: ENV["VAPID_PRIVATE_KEY"].to_s }
  end

  def self.vapid_configured?
    ENV["VAPID_PUBLIC_KEY"].present? && ENV["VAPID_PRIVATE_KEY"].present?
  end

  def self.base_url
    ENV.fetch("MYJIRA_BASE_URL", "http://localhost:1200")
  end
end
