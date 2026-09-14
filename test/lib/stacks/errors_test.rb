require "test_helper"

class StacksErrorsTest < ActiveSupport::TestCase
  test "Unexpected is defined, renders a generic 500, and does not leak the underlying message" do
    err = Stacks::Errors::Unexpected.new("Unhandled exception", RuntimeError.new("SECRET upstream body"))
    assert_equal :internal_server_error, err.status
    body = err.as_json.to_json
    assert_includes body, "Unexpected Error"
    refute_includes body, "SECRET upstream body"
  end
end
