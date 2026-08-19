require 'test_helper'

class StacksAIProvidersAnthropicTest < ActiveSupport::TestCase
  SCHEMA = {
    "type" => "object",
    "properties" => { "n" => { "type" => "integer" } },
    "required" => ["n"],
    "additionalProperties" => false
  }.freeze

  def setup
    Stacks::Utils.stubs(:config).returns({ anthropic: { api_key: "sk-test" } })
  end

  def fake_response(code: 200, body: {})
    resp = mock
    resp.stubs(:code).returns(code)
    resp.stubs(:parsed_response).returns(body)
    resp.stubs(:headers).returns({})
    resp
  end

  def success_body(text: '{"n": 3}', stop: "end_turn")
    { "content" => [{ "type" => "text", "text" => text }],
      "stop_reason" => stop,
      "usage" => { "input_tokens" => 100, "output_tokens" => 20 } }
  end

  test "posts the structured-output request shape and parses the result" do
    Stacks::AI::Providers::Anthropic.expects(:post).with do |path, opts|
      body = JSON.parse(opts[:body])
      path == "/messages" &&
        body["model"] == "claude-haiku-4-5" &&
        body.dig("output_config", "format", "type") == "json_schema" &&
        body.dig("output_config", "format", "schema") == SCHEMA &&
        opts[:headers]["x-api-key"] == "sk-test" &&
        opts[:headers]["anthropic-version"] == "2023-06-01"
    end.returns(fake_response(body: success_body))

    result = Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    assert_equal({ "n" => 3 }, result.data)
    assert_equal 100, result.input_tokens
    assert_equal 20, result.output_tokens
  end

  test "retries 429 then succeeds" do
    Stacks::AI::Providers::Anthropic.stubs(:sleep)
    Stacks::AI::Providers::Anthropic.expects(:post).twice
      .returns(fake_response(code: 429), fake_response(body: success_body))
    result = Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    assert_equal({ "n" => 3 }, result.data)
  end

  test "raises after exhausting retries on 529" do
    Stacks::AI::Providers::Anthropic.stubs(:sleep)
    Stacks::AI::Providers::Anthropic.stubs(:post).returns(fake_response(code: 529))
    assert_raises(Stacks::AI::Error) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    end
  end

  test "raises immediately on 400 without retrying" do
    Stacks::AI::Providers::Anthropic.expects(:post).once
      .returns(fake_response(code: 400, body: { "error" => { "message" => "bad" } }))
    assert_raises(Stacks::AI::Error) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    end
  end

  test "raises on stop_reason max_tokens" do
    Stacks::AI::Providers::Anthropic.stubs(:post)
      .returns(fake_response(body: success_body(stop: "max_tokens")))
    assert_raises(Stacks::AI::Error) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    end
  end

  test "raises when required schema keys are missing from the parsed payload" do
    Stacks::AI::Providers::Anthropic.stubs(:post)
      .returns(fake_response(body: success_body(text: '{"other": 1}')))
    assert_raises(Stacks::AI::Error) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    end
  end

  test "200 with non-Hash body (e.g. proxy HTML) raises Stacks::AI::Error" do
    Stacks::AI::Providers::Anthropic.stubs(:post)
      .returns(fake_response(code: 200, body: "<html>Bad Gateway</html>"))
    assert_raises(Stacks::AI::Error) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    end
  end

  test "configured? false without a key; extract raises" do
    Stacks::Utils.stubs(:config).returns({})
    refute Stacks::AI::Providers::Anthropic.configured?
    assert_raises(Stacks::AI::Error) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :fast)
    end
  end

  test "unknown tier raises" do
    assert_raises(ArgumentError) do
      Stacks::AI::Providers::Anthropic.extract(system: "s", prompt: "p", schema: SCHEMA, tier: :galaxy)
    end
  end
end
