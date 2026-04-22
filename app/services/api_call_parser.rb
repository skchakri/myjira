# Parses a test case's `api_call` string into a struct the executor can run.
#
# Supported formats (all case-insensitive on the method):
#
#   GET /api/v1/foo
#
#   POST /api/v1/foo {"name":"x"}
#
#   POST http://host/api/v1/foo
#   Headers: A=1; B=2; Content-Type: application/json
#   Body: {"name":"x"}
#
# Anything that starts with `browser:` (or has no HTTP method on line 1) is
# returned with executable: false — the run executor will mark those as
# blocked with a "requires manual/extension execution" note.
class ApiCallParser
  HTTP_METHODS = %w[GET POST PUT PATCH DELETE HEAD OPTIONS].freeze

  Parsed = Struct.new(:method, :url, :headers, :body, :executable, :reason, keyword_init: true)

  def self.parse(raw, base_url: nil, variables: {})
    text = raw.to_s.strip
    return blocked("empty api_call") if text.empty?
    return blocked("browser/manual step") if text =~ /\Abrowser:/i

    lines = text.split(/\r?\n/).map(&:strip).reject(&:empty?)
    first = lines.shift.to_s
    m = first.match(/\A(#{HTTP_METHODS.join("|")})\s+(\S+)(?:\s+(.*))?\z/i)
    return blocked("no HTTP method on first line") unless m

    method    = m[1].upcase
    url_raw   = m[2]
    inline_tail = m[3].to_s.strip

    headers = {}
    body = nil

    if inline_tail.start_with?("{", "[")
      body = inline_tail
    end

    lines.each do |ln|
      if ln =~ /\A[Hh]eaders?:\s*(.+)\z/
        $1.split(/;\s*/).each do |pair|
          if pair =~ /\A([A-Za-z0-9_\-]+)\s*[:=]\s*(.+)\z/
            headers[$1] = $2.strip
          end
        end
      elsif ln =~ /\A[Bb]ody:\s*(.*)\z/
        body = $1
      elsif body && (ln.start_with?("{") || ln.start_with?("["))
        body = ln
      elsif body.nil? && (ln.start_with?("{") || ln.start_with?("["))
        body = ln
      end
    end

    url = absolute_url(url_raw, base_url)
    return blocked("URL is relative and no env base_url is set: #{url_raw}") if url.nil?

    url = substitute(url, variables)
    body = substitute(body, variables) if body
    headers = headers.transform_values { |v| substitute(v, variables) }

    Parsed.new(method: method, url: url, headers: headers, body: body, executable: true, reason: nil)
  end

  def self.blocked(reason)
    Parsed.new(executable: false, reason: reason, headers: {}, body: nil)
  end

  def self.absolute_url(url_raw, base_url)
    return url_raw if url_raw =~ %r{\Ahttps?://}i
    return nil if base_url.to_s.strip.empty?
    URI.join(base_url.to_s.chomp("/") + "/", url_raw.sub(%r{\A/}, "")).to_s
  end

  def self.substitute(str, vars)
    return str if str.nil? || vars.blank?
    str.gsub(/\{([A-Za-z_][A-Za-z0-9_]*)\}/) { vars[$1] || vars[$1.to_sym] || "{#{$1}}" }
  end
end
