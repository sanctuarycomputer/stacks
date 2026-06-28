require "test_helper"

class LedgerTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: Enterprise::SANCTUARY_NAME)
    fp = ForecastPerson.create!(forecast_id: 991_001, email: "test@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
  end

  test "belongs to enterprise and contributor" do
    # Contributor.after_create already creates a Ledger for every enterprise,
    # so the (Sanctuary, @contributor) pair is already there — fetch it.
    ledger = Ledger.find_by!(enterprise: @enterprise, contributor: @contributor)
    assert_equal @enterprise, ledger.enterprise
    assert_equal @contributor, ledger.contributor
  end

  test "(enterprise, contributor) is unique" do
    # Already created by Contributor.after_create.
    assert Ledger.exists?(enterprise: @enterprise, contributor: @contributor)
    # Attempting to create another raises the AR uniqueness validation.
    assert_raises(ActiveRecord::RecordInvalid) do
      Ledger.create!(enterprise: @enterprise, contributor: @contributor)
    end
  end

  test ".find_or_create_for finds existing or creates new" do
    ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    assert ledger.persisted?
    same = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    assert_equal ledger, same
  end
end

class LedgerWithPayStubsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "LedgerStubs-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 998_001, email: "lstest@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    # Use find_or_create_for — Contributor.after_create + Enterprise.after_create
    # may have already created this pair (depending on which came first).
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
    @cycle = PayCycle.create!(enterprise: @enterprise, starts_at: Date.new(2026, 5, 1), ends_at: Date.new(2026, 5, 31))
    @admin = AdminUser.create!(email: "lsadm#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123")
  end

  test "balance counts payable pay stubs" do
    blueprint = { "lines" => [{ "amount" => 100.0, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] }
    PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 100, blueprint: blueprint, accepted_at: DateTime.now, accepted_by: @admin)
    # Cycle approval is now required for payable; grant the admin enterprise-admin and approve.
    @enterprise.admin_users << @admin
    @cycle.toggle_approval!(by: @admin)
    assert_equal 100, @ledger.balance.to_f
    assert_equal 0, @ledger.unsettled.to_f
  end

  test "unsettled counts un-payable pay stubs" do
    blueprint = { "lines" => [{ "amount" => 100.0, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] }
    PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 100, blueprint: blueprint)  # not accepted
    assert_equal 0, @ledger.balance.to_f
    assert_equal 100, @ledger.unsettled.to_f
  end

  test "all_items_with_deleted includes soft-deleted pay stubs" do
    blueprint = { "lines" => [{ "amount" => 100.0, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] }
    stub = PayStub.create!(pay_cycle: @cycle, ledger: @ledger, amount: 100, blueprint: blueprint)
    stub.destroy
    grouped = @ledger.items_grouped_by_month
    assert_includes grouped[:all].map(&:id), stub.id
  end
end

class LedgerEnsureAllTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
  end

  test "creates a Ledger for every (enterprise, contributor) pair" do
    e1 = Enterprise.find_or_create_by!(name: "EA-1-#{SecureRandom.hex(2)}")
    e2 = Enterprise.find_or_create_by!(name: "EA-2-#{SecureRandom.hex(2)}")
    fp1 = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ea1#{SecureRandom.hex(2)}@x.com", data: {})
    fp2 = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ea2#{SecureRandom.hex(2)}@x.com", data: {})
    c1 = Contributor.create!(forecast_person: fp1)
    c2 = Contributor.create!(forecast_person: fp2)

    # Idempotent — the after_create callbacks on Contributor / Enterprise may
    # have already filled the grid by this point.
    Ledger.ensure_all!

    [c1, c2].each do |c|
      [e1, e2].each do |e|
        assert Ledger.exists?(contributor: c, enterprise: e),
          "expected a Ledger for contributor=#{c.id}, enterprise=#{e.id}"
      end
    end
  end

  test "is idempotent — second call inserts nothing" do
    Ledger.ensure_all!
    inserted = Ledger.ensure_all!
    assert_equal 0, inserted
  end

  test "respects the (enterprise, contributor) uniqueness constraint" do
    e = Enterprise.find_or_create_by!(name: "EA-Uniq-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "uniq#{SecureRandom.hex(2)}@x.com", data: {})
    c = Contributor.create!(forecast_person: fp)
    # Contributor.after_create already creates the ledger; this Create raises uniqueness
    # if attempted again, so use find_or_create_for to remain idempotent.
    Ledger.find_or_create_for(enterprise: e, contributor: c)
    assert_nothing_raised { Ledger.ensure_all! }
    # Only one Ledger for this pair after ensure_all!.
    assert_equal 1, Ledger.where(enterprise: e, contributor: c).count
  end
end

class LedgerAfterCreateCallbacksTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    # Make sure Sanctuary exists so Contributor.after_create has at least
    # one enterprise to create a ledger against.
    @sanctuary = Enterprise.find_or_create_by!(name: Enterprise::SANCTUARY_NAME)
  end

  test "Contributor.after_create creates a Ledger for every existing enterprise" do
    other = Enterprise.find_or_create_by!(name: "AC-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ac#{SecureRandom.hex(2)}@x.com", data: {})
    c = Contributor.create!(forecast_person: fp)
    assert Ledger.exists?(contributor: c, enterprise: @sanctuary), "expected ledger for Sanctuary"
    assert Ledger.exists?(contributor: c, enterprise: other), "expected ledger for the other enterprise"
  end

  test "Enterprise.after_create creates a Ledger for every existing contributor" do
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "ec#{SecureRandom.hex(2)}@x.com", data: {})
    c = Contributor.create!(forecast_person: fp)
    new_enterprise = Enterprise.create!(name: "ECE-#{SecureRandom.hex(2)}")
    assert Ledger.exists?(contributor: c, enterprise: new_enterprise),
      "expected new enterprise to backfill ledgers for existing contributors"
  end

  test "Contributor.after_create is idempotent when ledger already exists" do
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "idem#{SecureRandom.hex(2)}@x.com", data: {})
    # Build the Contributor without saving; manually pre-create one ledger so
    # the after_create callback finds it already there.
    c = Contributor.new(forecast_person: fp)
    c.save!
    # Calling the callback method again should be a no-op (rows already exist).
    assert_nothing_raised { c.ensure_ledgers_for_all_enterprises! }
    assert_equal 0, Ledger.ensure_for_contributor!(c), "expected zero new rows on second call"
  end
end

class LedgerModeAndPaymentMethodsTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "ModeTest-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 992_001, email: "mode#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
  end

  test "mode defaults to qbo_bound for newly created ledgers" do
    assert_equal "qbo_bound", @ledger.mode
    assert @ledger.qbo_bound?
    refute @ledger.legacy?
  end

  test "mode flips to qbo_bound" do
    @ledger.update!(mode: :qbo_bound)
    assert @ledger.qbo_bound?
    refute @ledger.legacy?
  end

  test "deel_enabled? and qbo_enabled? reflect payment_methods" do
    @ledger.update!(payment_methods: %w[deel])
    assert @ledger.deel_enabled?
    refute @ledger.qbo_enabled?

    @ledger.update!(payment_methods: %w[qbo])
    refute @ledger.deel_enabled?
    assert @ledger.qbo_enabled?
  end

  test "PAYMENT_METHODS is the canonical list" do
    assert_equal %w[deel qbo], Ledger::PAYMENT_METHODS
  end

  test "validation rejects unknown payment_methods values" do
    @ledger.payment_methods = %w[deel justworks]
    refute @ledger.valid?
    assert_match(/justworks/, @ledger.errors[:payment_methods].join)
  end

  test "payment_methods_for: non-US Deel contributor → [deel]" do
    dp = DeelPerson.create!(deel_id: "dp#{SecureRandom.hex(2)}", data: { "country" => "CA" })
    c = Contributor.create!(forecast_person: ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "fr#{SecureRandom.hex(2)}@example.com", data: {}), deel_person_id: dp.deel_id)
    assert_equal %w[deel], Ledger.payment_methods_for(c)
  end

  test "payment_methods_for: US Deel contributor → [qbo]" do
    dp = DeelPerson.create!(deel_id: "dp#{SecureRandom.hex(2)}", data: { "country" => "US" })
    c = Contributor.create!(forecast_person: ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "us#{SecureRandom.hex(2)}@example.com", data: {}), deel_person_id: dp.deel_id)
    assert_equal %w[qbo], Ledger.payment_methods_for(c)
  end

  test "payment_methods_for: no Deel attachment → [qbo]" do
    c = Contributor.create!(forecast_person: ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "nd#{SecureRandom.hex(2)}@example.com", data: {}))
    assert_equal %w[qbo], Ledger.payment_methods_for(c)
  end

  test "ensure_for_contributor! sets payment_methods from contributor's deel country" do
    Enterprise.find_or_create_by!(name: "DefaultPMBulk-#{SecureRandom.hex(2)}")
    dp = DeelPerson.create!(deel_id: "dp#{SecureRandom.hex(2)}", data: { "country" => "DE" })
    c = Contributor.create!(forecast_person: ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "dpm#{SecureRandom.hex(2)}@example.com", data: {}), deel_person_id: dp.deel_id)
    # Contributor.after_create runs Ledger.ensure_for_contributor!; every ledger
    # for c should have payment_methods set from payment_methods_for(c).
    Ledger.where(contributor: c).each do |l|
      assert_equal %w[deel], l.payment_methods, "ensure_for_contributor! should populate payment_methods"
    end
  end

  test "default_payment_methods callback fires when a Ledger is built directly" do
    # Build (not create) so the auto-create from Contributor.after_create doesn't preempt us.
    dp = DeelPerson.create!(deel_id: "dp#{SecureRandom.hex(2)}", data: { "country" => "DE" })
    c = Contributor.create!(forecast_person: ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "cb#{SecureRandom.hex(2)}@example.com", data: {}), deel_person_id: dp.deel_id)
    l = Ledger.new(enterprise: Enterprise.find_or_create_by!(name: "CB-#{SecureRandom.hex(2)}"), contributor: c)
    assert_equal [], l.payment_methods, "blank before validation"
    l.valid?
    assert_equal %w[deel], l.payment_methods, "callback should fill the default"
  end
end


class LedgerBalanceUnderQboBoundTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    @enterprise = Enterprise.find_or_create_by!(name: "QBoundBal-#{SecureRandom.hex(2)}")
    fp = ForecastPerson.create!(forecast_id: 994_001, email: "qbb#{SecureRandom.hex(2)}@example.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)
    @ledger = Ledger.find_or_create_for(enterprise: @enterprise, contributor: @contributor)
  end

  test "legacy mode uses legacy rule (Reimbursement counts when accepted?)" do
    @ledger.update!(mode: :legacy)
    admin = AdminUser.create!(email: "qbblg#{SecureRandom.hex(2)}@example.com", password: "password123", password_confirmation: "password123")
    r = Reimbursement.create!(ledger: @ledger, amount: 100, description: "test reimbursement", receipts: "", accepted_at: Time.current, accepted_by: admin)
    assert_equal 100, @ledger.balance.to_f
  end

  test "qbo_bound mode drops a paid host from BOTH balance and unsettled" do
    @ledger.update!(mode: :qbo_bound)
    paid = mock("qbo_bill"); paid.stubs(:paid?).returns(true)
    payout = mock("payout")
    payout.stubs(:payable?).returns(true)
    payout.stubs(:qbo_bill).returns(paid)
    payout.stubs(:signed_amount).returns(100)
    payout.stubs(:is_a?).returns(false)
    payout.stubs(:is_a?).with(DeelInvoiceAdjustment).returns(false)
    payout.stubs(:is_a?).with(ContributorAdjustment).returns(false)

    @ledger.stubs(:visible_items).returns([payout])
    assert_equal 0, @ledger.balance.to_f, "paid host must not be in balance"
    assert_equal 0, @ledger.unsettled.to_f, "paid host must not be in unsettled either — it's done"
  end

  test "qbo_bound mode keeps a non-payable host in unsettled" do
    @ledger.update!(mode: :qbo_bound)
    pending = mock("pending_payout")
    pending.stubs(:payable?).returns(false)
    pending.stubs(:signed_amount).returns(100)
    pending.stubs(:qbo_bill).returns(nil)
    pending.stubs(:is_a?).returns(false)
    pending.stubs(:is_a?).with(DeelInvoiceAdjustment).returns(false)
    pending.stubs(:is_a?).with(ContributorAdjustment).returns(false)

    @ledger.stubs(:visible_items).returns([pending])
    assert_equal 0, @ledger.balance.to_f
    assert_equal 100, @ledger.unsettled.to_f
  end

  test "qbo_bound mode ignores DIAs entirely" do
    @ledger.update!(mode: :qbo_bound)
    dia = mock("dia")
    dia.stubs(:is_a?).returns(false)
    dia.stubs(:is_a?).with(DeelInvoiceAdjustment).returns(true)
    dia.stubs(:signed_amount).returns(-50)

    @ledger.stubs(:visible_items).returns([dia])
    assert_equal 0, @ledger.balance.to_f
    assert_equal 0, @ledger.unsettled.to_f
  end

  test "qbo_bound mode ignores negative CAs" do
    @ledger.update!(mode: :qbo_bound)
    neg = mock("neg_ca")
    neg.stubs(:is_a?).returns(false)
    neg.stubs(:is_a?).with(DeelInvoiceAdjustment).returns(false)
    neg.stubs(:is_a?).with(ContributorAdjustment).returns(true)
    neg.stubs(:amount).returns(-100)
    neg.stubs(:signed_amount).returns(-100)

    @ledger.stubs(:visible_items).returns([neg])
    assert_equal 0, @ledger.balance.to_f
    assert_equal 0, @ledger.unsettled.to_f
  end

  test "qbo_bound mode contributes the QBO bill's remaining balance for partial payments" do
    @ledger.update!(mode: :qbo_bound)
    partial = mock("qbo_bill"); partial.stubs(:paid?).returns(false); partial.stubs(:remaining_balance).returns(0.4)
    host = mock("partial_payout")
    host.stubs(:payable?).returns(true)
    host.stubs(:qbo_bill).returns(partial)
    host.stubs(:qbo_bound_balance_amount).returns(0.4)
    host.stubs(:amount).returns(1778.4)
    host.stubs(:signed_amount).returns(1778.4)
    host.stubs(:is_a?).returns(false)
    host.stubs(:is_a?).with(DeelInvoiceAdjustment).returns(false)
    host.stubs(:is_a?).with(ContributorAdjustment).returns(false)

    @ledger.stubs(:visible_items).returns([host])
    assert_in_delta 0.4, @ledger.balance.to_f, 0.001, "contribution should be qbo_bill.remaining_balance, not amount"
    assert_equal 0, @ledger.unsettled.to_f
  end
end
