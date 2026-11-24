require "open3"

module WorkQueue
  # Picks model + effort for each phase of a server-run item.
  #  (a) a fast router call: claude-haiku-5-5 at low effort, structured output
  #      validated against ALLOWED here (invalid output → fallback);
  #  (b) the routing table (editable, Redis) as fallback and ceiling: on a first
  #      attempt the router may pick something cheaper than the table, never a
  #      stronger model or more than xhigh effort;
  #  plus escalation after a retry / failed test leg, and per-item override/lock.
  #
  # Escalation is one step per failed attempt: first up the model ladder at the
  # same effort, then (already on the top model) one effort level, never past
  # xhigh. With the defaults a plan goes sonnet/high → opus/high → opus/xhigh.
  class Router
    MODELS = %w[claude-opus-5-5 claude-sonnet-5-5 claude-haiku-5-5 claude-fable-5-2].freeze
    LADDER = %w[claude-haiku-5-5 claude-sonnet-5-5 claude-opus-5-5].freeze # escalation order
    EFFORTS = %w[low medium high xhigh max].freeze
    PHASES = %w[plan implement review trivial].freeze
    ROUTER_MODEL = "claude-haiku-5-5".freeze
    # Escalation and the router never go to max; only you can, by override or the table.
    EFFORT_CEILING = "xhigh".freeze

    DEFAULTS = {
      "plan" => { "model" => "claude-sonnet-5-5", "effort" => "high" },
      "implement" => { "model" => "claude-sonnet-5-5", "effort" => "medium" },
      "review" => { "model" => "claude-opus-5-5", "effort" => "high" },
      "trivial" => { "model" => "claude-haiku-5-5", "effort" => "low" }
    }.freeze

    SCHEMA = {
      type: "object", additionalProperties: false, required: %w[model effort reason],
      properties: { model: { type: "string", enum: MODELS }, effort: { type: "string", enum: EFFORTS },
                    reason: { type: "string", maxLength: 200 } }
    }.freeze

    Choice = Struct.new(:model, :effort, :reason, :source, keyword_init: true)

    def initialize(runner: method(:claude))
      @runner = runner
    end

    def self.valid?(model, effort) = MODELS.include?(model.to_s) && EFFORTS.include?(effort.to_s)

    # item: Store::Item; run: RunState hash; context: { repo_files:, plan_chars:, diff_lines: }
    def choose(item, phase, run: {}, context: {}, attempts: 0)
      table = RunState.routing.fetch(phase, DEFAULTS.fetch(phase))
      if run["lock_model"] == "1" && self.class.valid?(run["override_model"], run["override_effort"])
        return Choice.new(model: run["override_model"], effort: run["override_effort"], reason: "locked by you", source: "lock")
      end

      routed = ask_router(item, phase, context)
      choice = routed ? cap(routed, table) : Choice.new(model: table["model"], effort: table["effort"],
                                                        reason: "routing table default", source: "table")
      if self.class.valid?(run["override_model"], run["override_effort"])
        choice = Choice.new(model: run["override_model"], effort: run["override_effort"], reason: "your override", source: "override")
      end
      attempts.positive? ? escalate(choice, attempts) : choice
    end

    # One step per failed attempt: a stronger model first, then more effort (up to xhigh).
    def escalate(choice, attempts)
      model, effort = self.class.climb(choice.model, choice.effort, attempts)
      Choice.new(model: model, effort: effort, reason: "escalated after #{attempts} failed attempt(s); #{choice.reason}", source: "escalation")
    end

    def self.climb(model, effort, steps)
      steps.times do
        i = LADDER.index(model)
        if i && i < LADDER.size - 1
          model = LADDER[i + 1]
        elsif EFFORTS.index(effort).to_i < EFFORTS.index(EFFORT_CEILING)
          effort = EFFORTS[EFFORTS.index(effort).to_i + 1]
        end
      end
      [model, effort]
    end

    # [[model, effort]] a phase goes through: the first attempt, then each retry.
    def self.ladder(model, effort, retries: 2)
      (0..retries).map { |n| climb(model, effort, n) }
    end

    private

    # The routing table is the ceiling for a first attempt: the router can go cheaper, not dearer.
    def cap(choice, table)
      model = choice.model
      rank = LADDER.index(model)
      limit = LADDER.index(table["model"])
      model = table["model"] if rank && limit && rank > limit
      top = [EFFORTS.index(table["effort"]).to_i, EFFORTS.index(EFFORT_CEILING)].max
      effort = EFFORTS[[EFFORTS.index(choice.effort).to_i, top].min]
      return choice if model == choice.model && effort == choice.effort

      Choice.new(model: model, effort: effort, reason: "#{choice.reason} (capped by the routing table)".truncate(200), source: "router")
    end

    def ask_router(item, phase, context)
      prompt = <<~PROMPT
        Pick the Claude model and reasoning effort for one phase of a coding task. Prefer the cheapest
        model that will reliably succeed. Phase: #{phase}. Title: #{item.title}
        Requirement (truncated): #{item.description.to_s.truncate(1500)}
        Repo files: #{context[:repo_files] || 'unknown'}; plan chars: #{context[:plan_chars] || 0}; diff lines: #{context[:diff_lines] || 0}.
        Guide: plan small or ordinary tasks on claude-sonnet-5-5 at high effort; keep claude-opus-5-5 for large,
        cross-cutting or risky work. Routine implementation is mid-tier; lint/typos are trivial. Never pick max effort.
        Answer with model, effort and a one-line reason.
      PROMPT
      out, ok = @runner.call(prompt)
      return unless ok

      j = JSON.parse(out)
      data = j["structured_output"] || (j["result"].is_a?(String) ? JSON.parse(j["result"]) : j["result"])
      return unless data.is_a?(Hash) && self.class.valid?(data["model"], data["effort"])

      Choice.new(model: data["model"], effort: data["effort"], reason: data["reason"].to_s.truncate(200), source: "router")
    rescue JSON::ParserError, TypeError
      nil
    end

    def claude(prompt)
      out, status = Open3.capture2("claude", "-p", "--model", ROUTER_MODEL, "--effort", "low", "--output-format", "json",
                                   "--json-schema", SCHEMA.to_json, "--permission-mode", "dontAsk", stdin_data: prompt)
      [out, status.success?]
    rescue SystemCallError
      ["", false]
    end
  end
end
