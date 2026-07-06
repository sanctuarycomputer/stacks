require "test_helper"

class DeelContractTest < ActiveSupport::TestCase
  test "deel_legal_entity_name reads from data[client][legal_entity][name]" do
    dc = DeelContract.new(data: { "client" => { "legal_entity" => { "name" => "Garden3D LLC" } } })
    assert_equal "Garden3D LLC", dc.deel_legal_entity_name
  end

  test "deel_legal_entity_name returns nil when not present" do
    assert_nil DeelContract.new(data: {}).deel_legal_entity_name
    assert_nil DeelContract.new(data: { "client" => {} }).deel_legal_entity_name
  end
end
