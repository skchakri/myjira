require "open3"

module WorkQueue
  # Suggested one-click answers for open questions that came without options.
  # A fast Claude call (haiku, low effort, JSON schema) runs on the host runner
  # (the container has no claude CLI); results are cached in Redis and pushed
  # to every open page as a chips replace.
  module Suggestions
    MODEL = Router::ROUTER_MODEL
    TTL = 7.days.to_i
    PENDING_TTL = 120
    SCHEMA = { type: "object", required: ["answers"], additionalProperties: false,
               properties: { answers: { type: "array", minItems: 2, maxItems: 4, items: { type: "string" } } } }.freeze

    module_function

    def redis = RunState.redis
    def digest(question) = Digest::SHA256.hexdigest(question.to_s)[0, 16]
    def cache_key(question) = "#{RunState::PREFIX}:sugg:#{digest(question)}"
    def dom_class(item, question) = "wq-sugg-#{item.slug}-#{item.n}-#{digest(question)}"
    def chip_id(item, index, answer) = "wq_sugg_#{item.key.parameterize}_#{index}_#{digest(answer)[0, 10]}"

    def get(question)
      raw = redis.get(cache_key(question))
      raw && JSON.parse(raw)
    rescue JSON::ParserError, Redis::BaseError
      nil
    end

    # Cached answers, or nil after asking the runner to generate them (once).
    def fetch_or_request(item, index, question)
      cached = get(question)
      return cached if cached
      return if RunState.runner.nil?

      RunState.enqueue("suggest", item.key, index: index, q: question) if redis.set("#{cache_key(question)}:pending", 1, nx: true, ex: PENDING_TTL)
      nil
    rescue Redis::BaseError
      nil
    end

    # 2-4 distinct, short strings or nil.
    def validate(list)
      return unless list.is_a?(Array)

      out = list.grep(String).map { |s| s.strip.gsub(/\s+/, " ") }.reject(&:blank?).map { |s| s.truncate(90) }.uniq.first(4)
      out.size >= 2 ? out : nil
    end

    # Runner side: generate, cache, broadcast.
    def generate(item, index, question, runner: method(:claude))
      prompt = <<~PROMPT
        A coding agent working on a task asked the person a question. Suggest 2-4 short, distinct likely answers
        (each under 12 words), the most sensible first. Answer only with the JSON.
        Task: #{item.title}
        Details (truncated): #{item.description.to_s.truncate(1200)}
        Question: #{question}
      PROMPT
      out, ok = runner.call(prompt)
      answers = ok ? validate(parse(out)) : nil
      return unless answers

      redis.set(cache_key(question), answers.to_json, ex: TTL)
      Turbo::StreamsChannel.broadcast_action_to(Broadcaster::LIST_STREAM, action: :replace, targets: ".#{dom_class(item, question)}",
                                                partial: "work_queue/suggestions",
                                                locals: { item: item, index: index, question: question, answers: answers })
      answers
    ensure
      redis.del("#{cache_key(question)}:pending")
    end

    def parse(out)
      j = JSON.parse(out.to_s)
      data = j["structured_output"] || (j["result"].is_a?(String) ? JSON.parse(j["result"][/\{.*\}/m].to_s) : j["result"])
      data.is_a?(Hash) ? data["answers"] : nil
    rescue JSON::ParserError, TypeError
      nil
    end

    def claude(prompt)
      out, status = Open3.capture2("claude", "-p", "--model", MODEL, "--effort", "low", "--output-format", "json",
                                   "--json-schema", SCHEMA.to_json, "--permission-mode", "dontAsk", stdin_data: prompt)
      [out, status.success?]
    rescue SystemCallError
      ["", false]
    end
  end
end
