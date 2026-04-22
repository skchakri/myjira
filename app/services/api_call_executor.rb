require "net/http"
require "uri"

# Executes one parsed api_call against the target env. Returns a result hash
# shaped like a TestResult update: { status:, actual_result:, notes: }.
#
# Status mapping:
#   2xx response        → pass
#   non-2xx response    → fail   (captures status + truncated body in notes)
#   network/DNS/timeout → blocked (captures error message)
#   not-executable      → blocked with reason from the parser
class ApiCallExecutor
  TIMEOUT = 15 # seconds
  MAX_BODY_CAPTURE = 800

  def self.run(parsed)
    return blocked(parsed.reason || "not executable") unless parsed.executable

    uri = URI.parse(parsed.url)
    req_class = {
      "GET" => Net::HTTP::Get, "POST" => Net::HTTP::Post, "PUT" => Net::HTTP::Put,
      "PATCH" => Net::HTTP::Patch, "DELETE" => Net::HTTP::Delete,
      "HEAD" => Net::HTTP::Head, "OPTIONS" => Net::HTTP::Options
    }[parsed.method] || Net::HTTP::Get

    req = req_class.new(uri)
    parsed.headers.each { |k, v| req[k] = v }
    if parsed.body && !%w[GET HEAD].include?(parsed.method)
      req["Content-Type"] ||= "application/json"
      req.body = parsed.body
    end

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = TIMEOUT
    http.read_timeout = TIMEOUT

    started = Time.current
    response = http.request(req)
    elapsed_ms = ((Time.current - started) * 1000).round

    status_class = response.code.to_i / 100
    body_preview = response.body.to_s[0, MAX_BODY_CAPTURE]
    actual = "HTTP #{response.code} · #{elapsed_ms}ms\n#{body_preview}"

    if status_class == 2
      { status: "pass", actual_result: actual, notes: nil }
    else
      { status: "fail", actual_result: actual, notes: "non-2xx response" }
    end
  rescue => e
    { status: "blocked", actual_result: nil, notes: "#{e.class}: #{e.message}" }
  end

  def self.blocked(reason)
    { status: "blocked", actual_result: nil, notes: reason }
  end
end
