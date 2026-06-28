require "test_helper"

class CostEstimatorTest < ActiveSupport::TestCase
  test "estimates opus input + output at list price" do
    # 1M input @ $15 + 1M output @ $75 = $90 = 9000 cents.
    cents = CostEstimator.cents(model: "opus", token_input: 1_000_000, token_output: 1_000_000)
    assert_equal 9000, cents
  end

  test "fuzzy-matches a raw claude-sonnet id" do
    # 2M input @ $3 = $6 = 600 cents.
    cents = CostEstimator.cents(model: "claude-sonnet-4-6", token_input: 2_000_000)
    assert_equal 600, cents
  end

  test "includes cache read + creation at their own rates" do
    # haiku: 1M cache_creation @ $1.25 + 1M cache_read @ $0.10 = $1.35 = 135 cents.
    cents = CostEstimator.cents(model: "haiku", cache_creation: 1_000_000, cache_read: 1_000_000)
    assert_equal 135, cents
  end

  test "unknown model is nil (caller renders n/a)" do
    assert_nil CostEstimator.cents(model: "gpt-4o", token_input: 1_000_000)
    assert_nil CostEstimator.cents(model: nil, token_input: 1_000_000)
  end

  test "all-zero usage is nil, not a fake $0" do
    assert_nil CostEstimator.cents(model: "opus", token_input: 0, token_output: 0)
  end

  test "rounds to whole cents" do
    # 100k opus output @ $75/MTok = $7.50 = 750 cents.
    assert_equal 750, CostEstimator.cents(model: "opus", token_output: 100_000)
  end
end
