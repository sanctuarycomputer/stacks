require "test_helper"

class PayStubTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "G3D-Stub-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 999_001, email: "stubtest@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @cycle = PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))
    @blueprint = { "lines" => [{ "forecast_project" => "fp-1", "hours" => 10, "rate" => 100, "amount" => 1000.0, "description" => "Test" }] }
    @admin = AdminUser.create!(email: "admin#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123")
  end

  test "valid with required fields" do
    stub = PayStub.new(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    assert stub.valid?, stub.errors.full_messages.inspect
  end

  test "delegates contributor and enterprise via LedgerItem" do
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    assert_equal @contributor, stub.contributor
    assert_equal @enterprise, stub.enterprise
  end

  test "uniqueness on (pay_cycle_id, ledger_id)" do
    PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    dup = PayStub.new(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    refute dup.valid?
  end

  test "rejects stub when pay_cycle.enterprise differs from ledger.enterprise" do
    other = Enterprise.find_or_create_by!(name: "Other-#{SecureRandom.hex(2)}")
    other_cycle = PayCycle.create!(enterprise: other, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))
    stub = PayStub.new(pay_cycle: other_cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    refute stub.valid?
    assert_includes stub.errors[:ledger], "must belong to the same enterprise as the pay_cycle"
  end

  test "amount must equal sum of blueprint lines (within rounding)" do
    stub = PayStub.new(pay_cycle: @cycle, ledger: @ledger, amount: 999, blueprint: @blueprint)
    refute stub.valid?
    assert_includes stub.errors[:amount], "must equal the sum of blueprint['lines'] amounts"
  end

  test "accepted_at and accepted_by must be both set or both nil" do
    stub = PayStub.new(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint, accepted_at: DateTime.now)
    refute stub.valid?
    assert_includes stub.errors[:accepted_by_id], "must be set when accepted_at is set"
  end

  test "payable? requires accepted AND all stubs in cycle accepted" do
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    refute stub.payable?
    stub.update!(accepted_at: DateTime.now, accepted_by: @admin)
    assert_equal :all_accepted, @cycle.reload.stubs_status
    assert stub.reload.payable?
  end

  test "toggle_acceptance! flips accepted_at and tracks accepted_by" do
    # Create a second stub so the cycle won't be :all_accepted after accepting just this one,
    # which would otherwise prevent un-acceptance (tested separately below).
    fp2 = ForecastPerson.create!(forecast_id: 999_002, email: "stubtest2@example.com", data: {})
    contributor2 = Contributor.create!(forecast_person: fp2)
    ledger2 = Ledger.find_or_create_for(enterprise: @enterprise, contributor: contributor2)
    PayStub.create!(pay_cycle: @cycle, ledger: ledger2, amount: 1000, blueprint: @blueprint)

    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    stub.toggle_acceptance!(by: @admin)
    assert stub.accepted?
    assert_equal @admin.id, stub.accepted_by_id
    stub.toggle_acceptance!(by: @admin)
    refute stub.accepted?
    assert_nil stub.accepted_by_id
  end

  test "toggle_acceptance! refuses unaccept when cycle is all_accepted" do
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint, accepted_at: DateTime.now, accepted_by: @admin)
    assert_equal :all_accepted, @cycle.reload.stubs_status
    assert_raises(RuntimeError, /Cannot unaccept/) do
      stub.toggle_acceptance!(by: @admin)
    end
  end

  test "effective_on_for_display is the cycle's ends_at" do
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    assert_equal @cycle.ends_at, stub.effective_on_for_display
  end
end
