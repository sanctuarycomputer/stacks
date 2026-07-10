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
    ActiveRecord::Base.connection.disable_referential_integrity do
      Enterprise.where(name: Enterprise::SANCTUARY_NAME).delete_all
    end
    assert_raises(ActiveRecord::RecordNotFound) { Enterprise.sanctuary }
  end

  test "deel_legal_entity_id can be set" do
    e = Enterprise.create!(name: "Garden3D LLC", deel_legal_entity_id: "le_abc123")
    assert_equal "le_abc123", e.reload.deel_legal_entity_id
  end
end

class EnterprisePayCycleCadenceTest < ActiveSupport::TestCase
  setup do
    @ent = Enterprise.create!(name: "Test Enterprise #{SecureRandom.hex(4)}")
  end

  test "pay_cycle_cadence is nullable" do
    assert_nil @ent.pay_cycle_cadence
  end

  test "pay_cycle_default_range_for monthly returns the whole calendar month" do
    @ent.update!(pay_cycle_cadence: "monthly")
    range = @ent.pay_cycle_default_range_for(Date.new(2026, 5, 20))
    assert_equal Date.new(2026, 5, 1), range.first
    assert_equal Date.new(2026, 5, 31), range.last
  end

  test "pay_cycle_default_range_for twice_monthly returns first half when day <= 15" do
    @ent.update!(pay_cycle_cadence: "twice_monthly")
    range = @ent.pay_cycle_default_range_for(Date.new(2026, 5, 15))
    assert_equal Date.new(2026, 5, 1), range.first
    assert_equal Date.new(2026, 5, 15), range.last
  end

  test "pay_cycle_default_range_for twice_monthly returns second half when day >= 16" do
    @ent.update!(pay_cycle_cadence: "twice_monthly")
    range = @ent.pay_cycle_default_range_for(Date.new(2026, 5, 16))
    assert_equal Date.new(2026, 5, 16), range.first
    assert_equal Date.new(2026, 5, 31), range.last
  end

  test "pay_cycle_default_range_for returns nil when cadence is unset" do
    assert_nil @ent.pay_cycle_default_range_for(Date.new(2026, 5, 20))
  end
end

class EnterpriseDailyTasksTest < ActiveSupport::TestCase
  test "is_index? is true only for Index Space, LLC" do
    index = Enterprise.find_or_create_by!(name: Enterprise::INDEX_SPACE_NAME)
    other = Enterprise.create!(name: "Some Other Enterprise #{SecureRandom.hex(4)}")
    assert index.is_index?
    refute other.is_index?
  end

  test "daily_tasks deactivates inactive Optix members for Index" do
    index = Enterprise.find_or_create_by!(name: Enterprise::INDEX_SPACE_NAME)
    Stacks::Optix.expects(:deactivate_inactive_members!).once
    index.daily_tasks
  end

  test "daily_tasks is a no-op for non-Index enterprises" do
    other = Enterprise.create!(name: "Some Other Enterprise #{SecureRandom.hex(4)}")
    Stacks::Optix.expects(:deactivate_inactive_members!).never
    other.daily_tasks
  end
end
