# Estimates the API $ cost of a captured Claude CLI run from its token usage.
# Pure (no DB) so it's trivially testable and callable on plucked tuples. Cost is
# returned in whole cents; an unknown model or all-zero usage → nil (callers must
# render "n/a", never a fake $0.00).
module CostEstimator
  module_function

  # Anthropic list price, in cents per MILLION tokens. Source: anthropic.com/pricing,
  # captured 2026-01. Keyed on the short model names in SessionLaunch::MODELS
  # (opus/sonnet/haiku); raw `claude-opus-*` / `-sonnet-*` / `-haiku-*` ids fuzzy-match.
  RATES = {
    "opus"   => { input: 1500, output: 7500, cache_creation: 1875, cache_read: 150 },
    "sonnet" => { input: 300,  output: 1500, cache_creation: 375,  cache_read: 30 },
    "haiku"  => { input: 100,  output: 500,  cache_creation: 125,  cache_read: 10 }
  }.freeze

  # Whole-cent estimate, or nil when the model is unknown or there's no usage yet.
  def cents(model:, token_input: 0, token_output: 0, cache_read: 0, cache_creation: 0)
    rate = rate_for(model)
    return nil unless rate

    tokens = { input: token_input, output: token_output,
               cache_read: cache_read, cache_creation: cache_creation }
    return nil if tokens.values.all? { |v| v.to_i.zero? }

    millicents = tokens.sum { |unit, count| count.to_i * rate[unit] }
    (millicents / 1_000_000.0).round
  end

  # The per-MTok rate hash for a model id, or nil if unrecognised.
  def rate_for(model)
    key = normalize(model)
    key && RATES[key]
  end

  def normalize(model)
    m = model.to_s.downcase
    return "opus"   if m.include?("opus")
    return "sonnet" if m.include?("sonnet")
    return "haiku"  if m.include?("haiku")
    nil
  end
end
