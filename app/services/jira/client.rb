require "net/http"
require "json"
require "uri"
require "stringio"

module Jira
  # Thin wrapper over the Jira Cloud REST API v3 using stdlib net/http. Fetches
  # and normalizes an issue, and downloads attachment bytes. All failures become
  # Jira::Error with a kind the controller can turn into a friendly message.
  class Client
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15
    MAX_REDIRECTS  = 5
    REDIRECT_CODES = [301, 302, 303, 307, 308].freeze
    ISSUE_FIELDS = "summary,description,issuetype,priority,status,assignee,reporter,labels,comment,attachment".freeze

    def initialize(connection)
      @connection = connection
    end

    def fetch_issue(key)
      resp = get(URI.parse("#{@connection.api_base}/issue/#{key}?fields=#{ISSUE_FIELDS}"))
      ok!(resp)
      normalize_issue(parse_json(resp.body))
    end

    def download_attachment(content_url)
      resp = get(URI.parse(content_url))
      ok!(resp)
      { io: StringIO.new(resp.body.to_s), content_type: resp["content-type"] }
    end

    private

    # GET following up to MAX_REDIRECTS redirects. Credentials are only attached
    # for the configured Jira host (see #request), so a redirect to a signed
    # media/S3 URL never leaks the token off-site.
    def get(uri, redirects_left: MAX_REDIRECTS)
      resp = request(uri)
      return resp unless redirect?(resp) && redirects_left.positive?

      location = resp["location"]
      return resp if location.nil? || location.empty?
      get(URI.join(uri.to_s, location), redirects_left: redirects_left - 1)
    end

    def redirect?(resp)
      REDIRECT_CODES.include?(resp.code.to_i)
    end

    def request(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = @connection.auth_header if same_host?(uri)
      req["Accept"] = "application/json"
      http.request(req)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError => e
      raise Jira::Error.new("Couldn't reach Jira (#{e.class}).", kind: :request_error)
    end

    def same_host?(uri)
      uri.host == @connection.host
    end

    def ok!(resp)
      code = resp.code.to_i
      return if code.between?(200, 299)
      case code
      when 401 then raise Jira::Error.new("Jira rejected the credentials.", kind: :unauthorized)
      when 403, 404 then raise Jira::Error.new("That Jira issue wasn't found, or you don't have access.", kind: :not_found)
      else raise Jira::Error.new("Jira request failed (HTTP #{code}).", kind: :request_error)
      end
    end

    def parse_json(body)
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      raise Jira::Error.new("Jira returned an unexpected response.", kind: :request_error)
    end

    def normalize_issue(json)
      f = json["fields"] || {}
      {
        key: json["key"],
        summary: f["summary"],
        description_adf: f["description"],
        issue_type: f.dig("issuetype", "name"),
        priority: f.dig("priority", "name"),
        status: f.dig("status", "name"),
        assignee: f.dig("assignee", "displayName"),
        reporter: f.dig("reporter", "displayName"),
        labels: Array(f["labels"]),
        comments: Array(f.dig("comment", "comments")).map do |c|
          { author: c.dig("author", "displayName"), created: c["created"], body_adf: c["body"] }
        end,
        attachments: Array(f["attachment"]).map do |a|
          { filename: a["filename"], mime: a["mimeType"], size: a["size"].to_i, content_url: a["content"] }
        end
      }
    end
  end
end
