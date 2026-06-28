# Per-model token pricing used to estimate cost for a CLI session.
# Rates are in USD per 1,000,000 tokens; matched by substring (case-insensitive)
# so "claude-opus-4-5", "opus-4", etc., all hit the right tier.
module ModelPricing
  RATES = [
    { match: "opus",   input: 15.0,  output: 75.0,  cache: 1.5  },
    { match: "sonnet", input: 3.0,   output: 15.0,  cache: 0.30 },
    { match: "haiku",  input: 0.80,  output: 4.0,   cache: 0.08 }
  ].freeze

  # Returns a BigDecimal cost (USD, rounded to 4 decimal places).
  # Returns 0 for an unknown / blank model.
  def self.cost_for(model:, input:, output:, cache: 0)
    tier = RATES.find { |r| model.to_s.downcase.include?(r[:match]) }
    return BigDecimal("0") unless tier

    cost = (
      input  * tier[:input]  +
      output * tier[:output] +
      cache  * tier[:cache]
    ) / 1_000_000.0

    BigDecimal(cost.to_s).round(4)
  end
end
