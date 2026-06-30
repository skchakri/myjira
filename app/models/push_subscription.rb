# One browser/device's Web Push endpoint + keys. Created by the web-push Stimulus
# controller when the user grants notification permission; pruned by WebPushNotifier
# when the push service reports the subscription gone (HTTP 410/404).
class PushSubscription < ApplicationRecord
  validates :endpoint, presence: true, uniqueness: true
  validates :p256dh, :auth, presence: true

  # Idempotent register: a browser re-subscribing with the same endpoint updates
  # its keys rather than creating a duplicate row.
  def self.upsert_from!(endpoint:, p256dh:, auth:, user_agent: nil)
    sub = find_or_initialize_by(endpoint: endpoint)
    sub.update!(p256dh: p256dh, auth: auth, user_agent: user_agent)
    sub
  end
end
