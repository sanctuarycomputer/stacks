require "test_helper"

class DeelContractTest < ActiveSupport::TestCase
  test "extract_legal_entity_id reads from data[client][legal_entity][id]" do
    dc = DeelContract.new(data: { "client" => { "legal_entity" => { "id" => "le_xyz" } } })
    assert_equal "le_xyz", dc.extract_legal_entity_id
  end

  test "extract_legal_entity_id returns nil when not present" do
    assert_nil DeelContract.new(data: {}).extract_legal_entity_id
    assert_nil DeelContract.new(data: { "client" => {} }).extract_legal_entity_id
  end
end
