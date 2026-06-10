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

  test "payable? requires accepted AND all stubs in cycle accepted AND cycle approved" do
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    refute stub.payable?
    stub.update!(accepted_at: DateTime.now, accepted_by: @admin)
    assert_equal :all_accepted, @cycle.reload.stubs_status
    refute stub.reload.payable?, "should still be unpayable until the cycle itself is approved"
    @enterprise.admin_users << @admin
    @cycle.toggle_approval!(by: @admin)
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

  # ---------------------------------------------------------------------------
  # payable? edge cases
  # ---------------------------------------------------------------------------

  test "payable? returns false for an accepted stub in a cycle that still has pending siblings" do
    fp2 = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "sibling#{SecureRandom.hex(2)}@example.com", data: {})
    contributor2 = Contributor.create!(forecast_person: fp2)
    ledger2 = Ledger.find_or_create_for(enterprise: @enterprise, contributor: contributor2)
    _pending = PayStub.create!(pay_cycle: @cycle, ledger: ledger2, amount: 1000, blueprint: @blueprint)

    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    stub.update!(accepted_at: DateTime.now, accepted_by: @admin)

    # Cycle still has one unaccepted stub → not :all_accepted → not payable.
    assert_equal :some_pending, @cycle.reload.stubs_status
    refute stub.reload.payable?
  end

  test "payable? returns true for the sole surviving accepted stub when soft-deleted sibling is excluded" do
    fp2 = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ghost#{SecureRandom.hex(2)}@example.com", data: {})
    contributor2 = Contributor.create!(forecast_person: fp2)
    ledger2 = Ledger.find_or_create_for(enterprise: @enterprise, contributor: contributor2)
    ghost = PayStub.create!(pay_cycle: @cycle, ledger: ledger2, amount: 1000, blueprint: @blueprint)

    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    stub.update!(accepted_at: DateTime.now, accepted_by: @admin)

    # Soft-delete the sibling — paranoia excludes it from the default scope,
    # so stubs_status should become :all_accepted.
    ghost.destroy
    assert_equal :all_accepted, @cycle.reload.stubs_status
    # Cycle approval is also required for payable now.
    @enterprise.admin_users << @admin
    @cycle.toggle_approval!(by: @admin)
    assert stub.reload.payable?
  end

  # ---------------------------------------------------------------------------
  # toggle_acceptance! repeatability
  # ---------------------------------------------------------------------------

  test "toggle_acceptance! can be called multiple times in succession (accept/unaccept/accept)" do
    # Keep a second stub so the cycle never reaches :all_accepted while we flip.
    fp2 = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "multi#{SecureRandom.hex(2)}@example.com", data: {})
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

    stub.toggle_acceptance!(by: @admin)
    assert stub.accepted?
    assert_equal @admin.id, stub.accepted_by_id
  end

  # ---------------------------------------------------------------------------
  # qbo_bill_id partial unique index
  # ---------------------------------------------------------------------------

  test "DB enforces uniqueness on non-nil qbo_bill_id via partial unique index" do
    fp2 = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "dup#{SecureRandom.hex(2)}@example.com", data: {})
    contributor2 = Contributor.create!(forecast_person: fp2)
    ledger2 = Ledger.find_or_create_for(enterprise: @enterprise, contributor: contributor2)

    shared_id = "DUPBILL-#{SecureRandom.hex(4)}"
    PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
      .update_columns(qbo_bill_id: shared_id)

    second = PayStub.create!(pay_cycle: @cycle, ledger: ledger2, amount: 1000, blueprint: @blueprint)
    # Wrap in a savepoint so PG doesn't leave the outer test transaction in aborted state.
    ActiveRecord::Base.transaction(requires_new: true) do
      assert_raises(ActiveRecord::RecordNotUnique) { second.update_columns(qbo_bill_id: shared_id) }
      raise ActiveRecord::Rollback
    end
  end

  test "partial unique index on qbo_bill_id permits multiple nil values" do
    fp2 = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "nil#{SecureRandom.hex(2)}@example.com", data: {})
    contributor2 = Contributor.create!(forecast_person: fp2)
    ledger2 = Ledger.find_or_create_for(enterprise: @enterprise, contributor: contributor2)

    PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 1000, blueprint: @blueprint)
    second = PayStub.new(pay_cycle: @cycle, ledger: ledger2, amount: 1000, blueprint: @blueprint)
    # Both have nil qbo_bill_id — partial index should not fire.
    assert second.valid?, second.errors.full_messages.inspect
    assert_nothing_raised { second.save! }
  end

  # ---------------------------------------------------------------------------
  # amount_matches_blueprint_sum tolerance
  # ---------------------------------------------------------------------------

  test "amount_matches_blueprint_sum passes when lines split into thirds that round to the same total" do
    # 33.33 + 33.33 + 33.34 sums to exactly 100.00 at 2dp.  The < 0.01 guard
    # protects against float epsilon after .round(2); this verifies no false
    # positive is raised for a legitimately balanced multi-line blueprint.
    bp = {
      "lines" => [
        { "forecast_project" => "fp-1", "hours" => 1, "rate" => 33, "amount" => 33.33, "description" => "A" },
        { "forecast_project" => "fp-1", "hours" => 1, "rate" => 33, "amount" => 33.33, "description" => "B" },
        { "forecast_project" => "fp-1", "hours" => 1, "rate" => 34, "amount" => 33.34, "description" => "C" },
      ],
    }
    stub = PayStub.new(pay_cycle: @cycle, ledger: @ledger, amount: 100.0, blueprint: bp)
    assert stub.valid?, stub.errors.full_messages.inspect
  end

  # ---------------------------------------------------------------------------
  # acceptance_pair_consistent validation
  # ---------------------------------------------------------------------------

  test "acceptance_pair_consistent rejects setting only accepted_by_id without accepted_at" do
    stub = PayStub.new(
      pay_cycle: @cycle,
      ledger: @ledger,
      amount: 1000,
      blueprint: @blueprint,
      accepted_by_id: @admin.id,
      accepted_at: nil,
    )
    refute stub.valid?
    assert_includes stub.errors[:accepted_at], "must be set when accepted_by_id is set"
  end

  test "new_deal_balance includes accepted PayStub in balance and unaccepted in unsettled" do
    # Accepted stub — cycle has only this one stub so stubs_status == :all_accepted.
    # The cycle itself must also be approved by an enterprise admin to flip payable?.
    accepted_stub = PayStub.create!(
      pay_cycle: @cycle,
      ledger: @ledger,
      amount: 1000,
      blueprint: @blueprint,
      accepted_at: DateTime.now,
      accepted_by: @admin,
    )
    @enterprise.admin_users << @admin
    @cycle.toggle_approval!(by: @admin)
    assert accepted_stub.payable?, "stub should be payable when accepted + cycle :all_accepted + cycle approved"

    balance = @contributor.new_deal_balance
    assert_equal 1000, balance[:balance], "accepted payable stub should appear in balance"
    assert_equal 0, balance[:unsettled], "no unsettled stubs yet"

    # Add a second cycle with an unaccepted stub — neither stub in that cycle is payable
    cycle2 = PayCycle.create!(
      enterprise: @enterprise,
      starts_at: Date.new(2026, 6, 1),
      ends_at: Date.new(2026, 6, 30),
    )
    blueprint2 = { "lines" => [{ "forecast_project" => "fp-2", "hours" => 5, "rate" => 100, "amount" => 500.0, "description" => "June" }] }
    pending_stub = PayStub.create!(pay_cycle: cycle2, ledger: @ledger, amount: 500, blueprint: blueprint2)
    refute pending_stub.payable?, "unaccepted stub should not be payable"

    # Re-check contributor (reset memoized cache by reloading)
    @contributor.instance_variable_set(:@_pay_stubs_with_deleted, nil)
    balance2 = @contributor.new_deal_balance
    assert_equal 1000, balance2[:balance], "accepted stub still in balance"
    assert_equal 500, balance2[:unsettled], "unaccepted stub appears in unsettled"

    # Cleanup
    pending_stub.destroy
    cycle2.destroy
  end
end

class PayStubBillLinesTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary, client_id: "x", client_secret: "y", realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ps#{SecureRandom.hex(2)}@x.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @contributor)
    @cycle = PayCycle.create!(enterprise: @sanctuary, starts_at: Date.new(2032, 1, 1), ends_at: Date.new(2032, 1, 31))

    @facilities = QboChartAccount.create!(qbo_account: @qa, qbo_id: "880", name: "Facilities Management Salaries", data: {})
    QboBillAccountMapping.create!(enterprise: @sanctuary, line_item_key: "pay_stub", qbo_chart_account_qbo_id: "880")
  end

  test "bill_line_items groups lines per forecast project at the pay_stub mapping" do
    blueprint = { "lines" => [
      { "amount" => 100.0, "hours" => 2.0, "forecast_project" => 111, "description" => "a" },
      { "amount" => 50.0,  "hours" => 1.0, "forecast_project" => 111, "description" => "b" },
      { "amount" => 25.0,  "hours" => 0.5, "forecast_project" => 222, "description" => "c" },
    ] }
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 175, blueprint: blueprint)

    lines = stub.bill_line_items

    assert_equal 2, lines.size
    amounts = lines.map(&:amount).sort
    assert_equal [25.0, 150.0], amounts
    lines.each do |line|
      assert_equal "880", line.account_based_expense_line_detail.account_ref.value
    end
  end

  test "bill_line_items honors a project-tracker-level pay_stub override" do
    tracker = ProjectTracker.new(name: "PSO-#{SecureRandom.hex(2)}")
    tracker.save!(validate: false)
    fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "PSC-#{SecureRandom.hex(2)}", data: {})
    fproj = ForecastProject.new(forecast_id: 333, client_id: fc.forecast_id, data: {})
    fproj.save!(validate: false)
    ProjectTrackerForecastProject.create!(project_tracker: tracker, forecast_project: fproj)

    override_acct = QboChartAccount.create!(qbo_account: @qa, qbo_id: "881", name: "Special Salaries", data: {})
    QboBillAccountMapping.create!(
      enterprise: @sanctuary, line_item_key: "pay_stub",
      project_tracker: tracker, qbo_chart_account_qbo_id: "881",
    )

    blueprint = { "lines" => [
      { "amount" => 100.0, "hours" => 2.0, "forecast_project" => 333, "description" => "tracked" },
      { "amount" => 50.0,  "hours" => 1.0, "forecast_project" => 999, "description" => "untracked" },
    ] }
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 150, blueprint: blueprint)

    lines = stub.bill_line_items

    tracked = lines.find { |l| l.amount == 100.0 }
    untracked = lines.find { |l| l.amount == 50.0 }
    assert_equal "881", tracked.account_based_expense_line_detail.account_ref.value
    assert_equal "880", untracked.account_based_expense_line_detail.account_ref.value
  end

  test "lines without a forecast_project group together and resolve contributor -> entity" do
    blueprint = { "lines" => [
      { "amount" => 30.0, "hours" => 1.0, "forecast_project" => nil, "description" => "x" },
      { "amount" => 20.0, "hours" => 0.5, "description" => "y" },
    ] }
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 50, blueprint: blueprint)

    lines = stub.bill_line_items

    assert_equal 1, lines.size, "nil and missing forecast_project entries form one group"
    assert_equal 50.0, lines.first.amount
    assert_equal "880", lines.first.account_based_expense_line_detail.account_ref.value
  end

  test "bill_line_items raises Qbo::UnmappedLineItemError when pay_stub is unmapped" do
    QboBillAccountMapping.where(enterprise: @sanctuary, line_item_key: "pay_stub").destroy_all
    blueprint = { "lines" => [{ "amount" => 10.0, "hours" => 1.0, "forecast_project" => 111, "description" => "x" }] }
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 10, blueprint: blueprint)

    assert_raises(Qbo::UnmappedLineItemError) { stub.bill_line_items }
  end
end
