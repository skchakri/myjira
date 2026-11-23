module ApplicationHelper
  # Returns the URL only when it is an absolute http(s) link, so stored values
  # like "javascript:…" never end up in an href. nil otherwise.
  def safe_external_url(url)
    uri = URI.parse(url.to_s.strip)
    return nil unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end
end
