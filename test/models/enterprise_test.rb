require "test_helper"

class EnterpriseTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
  end

  test ".sanctuary returns the Sanctuary Computer Inc row" do
    sanctu = Enterprise.find_or_create_by!(name: Enterprise::SANCTUARY_NAME)
    assert_equal sanctu, Enterprise.sanctuary
  end

  test ".sanctuary raises if Sanctuary Computer Inc is missing" do
    Enterprise.where(name: Enterprise::SANCTUARY_NAME).delete_all
    assert_raises(ActiveRecord::RecordNotFound) { Enterprise.sanctuary }
  end

  test "deel_legal_entity_id can be set" do
    e = Enterprise.create!(name: "Garden3D LLC", deel_legal_entity_id: "le_abc123")
    assert_equal "le_abc123", e.reload.deel_legal_entity_id
  end
end
