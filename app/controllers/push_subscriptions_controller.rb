# Browser <-> server registration of Web Push subscriptions. The web-push Stimulus
# controller POSTs the PushManager subscription here; DELETE removes it on unsubscribe.
class PushSubscriptionsController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    sub = params.require(:subscription)
    PushSubscription.upsert_from!(
      endpoint: sub[:endpoint],
      p256dh: sub.dig(:keys, :p256dh),
      auth: sub.dig(:keys, :auth),
      user_agent: request.user_agent
    )
    head :ok
  end

  def destroy
    PushSubscription.where(endpoint: params[:endpoint]).destroy_all
    head :no_content
  end
end
