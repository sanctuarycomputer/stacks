require 'test_helper'

class StacksAITest < ActiveSupport::TestCase
  SCHEMA = {
    "type" => "object",
    "properties" => { "answer" => { "type" => "string" } },
    "required" => ["answer"],
    "additionalProperties" => false
  }.freeze

  test "extract delegates to the configured provider and returns its result" do
    result = Stacks::AI::Result.new({ "answer" => "hi" }, 10, 5)
    Stacks::AI::Providers::Anthropic.expects(:extract)
      .with(system: "sys", prompt: "p", schema: SCHEMA, tier: :fast)
      .returns(result)
    out = Stacks::AI.extract(system: "sys", prompt: "p", schema: SCHEMA)
    assert_equal({ "answer" => "hi" }, out.data)
    assert_equal 10, out.input_tokens
  end

  test "configured? reflects the provider's key presence" do
    Stacks::AI::Providers::Anthropic.stubs(:configured?).returns(false)
    refute Stacks::AI.configured?
  end

  test "unknown provider raises" do
    Stacks::Utils.stubs(:config).returns({ ai: { provider: "openai" } })
    assert_raises(Stacks::AI::Error) { Stacks::AI.provider }
  end
end
