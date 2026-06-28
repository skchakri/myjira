require "test_helper"

class ModelPricingTest < ActiveSupport::TestCase
  test "opus tier cost" do
    # 1 input token, 1 output token, 0 cache
    cost = ModelPricing.cost_for(model: "claude-opus-4-5", input: 1_000_000, output: 0, cache: 0)
    assert_equal BigDecimal("15.0"), cost
  end

  test "opus tier output cost" do
    cost = ModelPricing.cost_for(model: "claude-opus-4-5", input: 0, output: 1_000_000, cache: 0)
    assert_equal BigDecimal("75.0"), cost
  end

  test "opus tier cache cost" do
    cost = ModelPricing.cost_for(model: "claude-opus-4-5", input: 0, output: 0, cache: 1_000_000)
    assert_equal BigDecimal("1.5"), cost
  end

  test "sonnet tier input cost" do
    cost = ModelPricing.cost_for(model: "claude-sonnet-4-5", input: 1_000_000, output: 0, cache: 0)
    assert_equal BigDecimal("3.0"), cost
  end

  test "sonnet tier output cost" do
    cost = ModelPricing.cost_for(model: "claude-sonnet-4-5", input: 0, output: 1_000_000, cache: 0)
    assert_equal BigDecimal("15.0"), cost
  end

  test "haiku tier input cost" do
    cost = ModelPricing.cost_for(model: "claude-haiku-4-5", input: 1_000_000, output: 0, cache: 0)
    assert_equal BigDecimal("0.8"), cost
  end

  test "haiku tier output cost" do
    cost = ModelPricing.cost_for(model: "claude-haiku-4-5", input: 0, output: 1_000_000, cache: 0)
    assert_equal BigDecimal("4.0"), cost
  end

  test "unknown model returns zero" do
    cost = ModelPricing.cost_for(model: "gpt-4", input: 1_000_000, output: 1_000_000, cache: 1_000_000)
    assert_equal BigDecimal("0"), cost
  end

  test "nil model returns zero" do
    cost = ModelPricing.cost_for(model: nil, input: 1_000_000, output: 1_000_000)
    assert_equal BigDecimal("0"), cost
  end

  test "match is case-insensitive" do
    cost = ModelPricing.cost_for(model: "Claude-Opus-4", input: 1_000_000, output: 0)
    assert_equal BigDecimal("15.0"), cost
  end

  test "mixed tokens sum correctly (rounded to 4 decimals)" do
    # opus: (1000 * 15 + 500 * 75 + 200 * 1.5) / 1_000_000 = (15000 + 37500 + 300) / 1_000_000
    # = 52800 / 1_000_000 = 0.0528
    cost = ModelPricing.cost_for(model: "claude-opus-4-5", input: 1000, output: 500, cache: 200)
    assert_equal BigDecimal("0.0528"), cost
  end
end
