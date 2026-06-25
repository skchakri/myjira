require "base64"
require "uri"

# Singleton credentials for the Atlassian Jira Cloud REST API. One row: the
# account whose email + API token myjira uses to read tickets on import. The
# token is encrypted at rest (Active Record Encryption).
class JiraConnection < ApplicationRecord
  encrypts :api_token

  validates :site_url, presence: true

  # The single configured connection (or nil / a fresh unsaved one).
  def self.current      = first
  def self.current_or_new = first || new
  def self.configured?  = current&.complete? || false

  def complete?
    site_url.present? && email.present? && api_token.present?
  end

  def host
    URI.parse(site_url.to_s).host
  rescue URI::InvalidURIError
    nil
  end

  def api_base
    "#{site_url.to_s.chomp('/')}/rest/api/3"
  end

  def auth_header
    "Basic " + Base64.strict_encode64("#{email}:#{api_token}")
  end
end
