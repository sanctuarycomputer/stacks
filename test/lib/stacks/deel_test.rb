require "test_helper"

class StacksDeelSyncContractsTest < ActiveSupport::TestCase
  test "sync_contracts! writes deel_legal_entity_id from contract detail payload" do
    DeelPerson.create!(deel_id: "p1", data: { "id" => "p1" })

    raw = [
      {
        "id" => "c1",
        "worker" => { "id" => "p1" },
        "client" => { "team" => { "id" => "team_abc", "name" => "Garden3D Team" } },
      },
    ]

    detail = {
      "id" => "c1",
      "worker" => { "id" => "p1" },
      "client" => { "legal_entity" => { "id" => "le_garden3d", "name" => "Garden3D LLC" } },
    }

    deel = Stacks::Deel.new
    deel.stubs(:get_contracts).returns(raw)
    deel.stubs(:get_contract_detail).with("c1").returns(detail)
    deel.sync_contracts!

    dc = DeelContract.find("c1")
    assert_equal "le_garden3d", dc.deel_legal_entity_id
  end
end
