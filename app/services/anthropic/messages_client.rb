require "net/http"
require "json"
require "uri"

module Anthropic
  # Thin Net::HTTP wrapper for the Anthropic Messages API. Only sends the bare
  # minimum needed for InstantTriageJob: a single user message, JSON response.
  class MessagesClient
    BASE_URL    = "https://api.anthropic.com/v1/messages".freeze
    API_VERSION = "2023-06-01".freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15

    def initialize(api_key:)
      @api_key = api_key
    end

    # Single user-turn call. Returns the first text content block as a String.
    def complete(model:, max_tokens:, system: nil, user:)
      body = { model: model, max_tokens: max_tokens, messages: [{ role: "user", content: user }] }
      body[:system] = system if system.present?

      resp = post(BASE_URL, body)
      ok!(resp)
      parse_text(resp.body)
    end

    private

    def post(url, payload)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      req = Net::HTTP::Post.new(uri)
      req["x-api-key"]         = @api_key
      req["anthropic-version"]  = API_VERSION
      req["content-type"]       = "application/json"
      req.body = payload.to_json

      http.request(req)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError => e
      raise Anthropic::Error, "Network error calling Anthropic API (#{e.class}): #{e.message}"
    end

    def ok!(resp)
      code = resp.code.to_i
      return if code.between?(200, 299)
      raise Anthropic::Error, "Anthropic API returned HTTP #{code}: #{resp.body.to_s.truncate(200)}"
    end

    def parse_text(body)
      json = JSON.parse(body.to_s)
      json.dig("content", 0, "text").to_s
    rescue JSON::ParserError => e
      raise Anthropic::Error, "Unexpected response from Anthropic API: #{e.message}"
    end
  end

  class Error < StandardError; end
end
