# Blocks the drive-by CSRF → RCE vector on the no-auth local API.
#
# The API queues SessionLaunches that the host daemon executes as unattended
# Claude sessions (some with bypassPermissions) in real repos — so any web page
# that could POST here from the user's browser could get code executed on the
# host. Browsers ALWAYS attach Origin / Sec-Fetch-Site to cross-origin POSTs,
# while every legitimate caller of this API (curl from board agents, the host
# daemon, the global myjira-* skills, the Stop hook) sends neither header. So:
#
#   - a cross-site browser request (Sec-Fetch-Site: cross-site, or an Origin
#     whose host isn't local) is rejected with 403;
#   - header-less callers (CLI/daemon) and same-origin browser fetches from the
#     app's own UI pass untouched;
#   - MYJIRA_API_TOKEN, when set, lets a legitimate remote caller through with
#     `Authorization: Bearer <token>` (none exist today; escape hatch only).
#
# This is deliberately NOT full authentication — myjira is a local, single-user
# app — it closes the specific "any website you visit can file work" hole.
module LocalApiProtection
  extend ActiveSupport::Concern

  TRUSTED_ORIGIN_HOSTS = %w[localhost 127.0.0.1 [::1] ::1].freeze

  included do
    before_action :block_cross_site_browser_requests!
  end

  private

  def block_cross_site_browser_requests!
    return if bearer_token_trusted?
    return forbid_api!("cross-site browser request") if request.headers["Sec-Fetch-Site"].to_s.casecmp?("cross-site")

    origin = request.headers["Origin"].presence
    return if origin.blank?

    # "Origin: null" (sandboxed iframe) parses to a nil host and is rejected below.
    host = begin
      URI.parse(origin).host
    rescue URI::InvalidURIError
      nil
    end
    forbid_api!("untrusted origin #{origin}") unless TRUSTED_ORIGIN_HOSTS.include?(host)
  end

  def bearer_token_trusted?
    expected = ENV["MYJIRA_API_TOKEN"].presence
    return false unless expected
    provided = request.headers["Authorization"].to_s.delete_prefix("Bearer").strip
    provided.present? && ActiveSupport::SecurityUtils.secure_compare(provided, expected)
  end

  def forbid_api!(reason)
    Rails.logger.warn("[api] blocked #{request.method} #{request.path}: #{reason}")
    render json: { error: "forbidden", message: "Cross-site browser requests are not allowed on this API." },
           status: :forbidden
  end
end
