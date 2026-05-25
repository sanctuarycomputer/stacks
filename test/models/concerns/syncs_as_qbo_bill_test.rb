require "test_helper"

# Tests the per-enterprise routing behavior of SyncsAsQboBill.
# Uses PayStub as the test host (any SyncsAsQboBill host would work).
class SyncsAsQboBillRoutingTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil

    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @sanctuary_qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )

    @other_enterprise = Enterprise.find_or_create_by!(name: "Other-#{SecureRandom.hex(2)}")

    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "sb#{SecureRandom.hex(2)}@x.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)

    @sanctuary_ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @contributor)
    @other_ledger = Ledger.find_or_create_for(enterprise: @other_enterprise, contributor: @contributor)

    @sanctuary_cycle = PayCycle.create!(enterprise: @sanctuary, starts_at: Date.new(2030, 5, 1), ends_at: Date.new(2030, 5, 31))
    @other_cycle = PayCycle.create!(enterprise: @other_enterprise, starts_at: Date.new(2030, 5, 1), ends_at: Date.new(2030, 5, 31))

    @blueprint = { "lines" => [{ "amount" => 100.0, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] }
  end

  test "qbo_account_for_bill returns the ledger's enterprise's qbo_account" do
    stub = PayStub.create!(pay_cycle: @sanctuary_cycle, ledger: @sanctuary_ledger, amount: 100, blueprint: @blueprint)
    assert_equal @sanctuary_qa, stub.qbo_account_for_bill
  end

  test "qbo_account_for_bill returns nil when the enterprise has no qbo_account" do
    stub = PayStub.create!(pay_cycle: @other_cycle, ledger: @other_ledger, amount: 100, blueprint: @blueprint)
    assert_nil stub.qbo_account_for_bill
  end

  test "qbo_bill returns nil when qbo_bill_id is blank" do
    stub = PayStub.create!(pay_cycle: @sanctuary_cycle, ledger: @sanctuary_ledger, amount: 100, blueprint: @blueprint)
    assert_nil stub.qbo_bill_id
    assert_nil stub.qbo_bill
  end

  test "qbo_bill resolves via composite (qbo_account_id, qbo_id) lookup" do
    vendor = QboVendor.create!(qbo_id: "VENDOR-X-#{SecureRandom.hex(2)}", qbo_account: @sanctuary_qa, data: { "display_name" => "Test Vendor" })
    bill = QboBill.create!(qbo_id: "TESTBILL#{SecureRandom.hex(2)}", qbo_account: @sanctuary_qa, qbo_vendor_id: vendor.qbo_id, data: {})
    stub = PayStub.create!(pay_cycle: @sanctuary_cycle, ledger: @sanctuary_ledger, amount: 100, blueprint: @blueprint, qbo_bill_id: bill.qbo_id)
    assert_equal bill, stub.qbo_bill
  end

  test "qbo_bill returns nil when same qbo_id exists in a DIFFERENT qbo_account" do
    # Two QboBill rows can now coexist with the same qbo_id under different qbo_accounts.
    # The stub's lookup must scope by its enterprise's qbo_account.
    other_qa = QboAccount.create!(enterprise: @other_enterprise, client_id: "x", client_secret: "y", realm_id: SecureRandom.hex(8))
    vendor = QboVendor.create!(qbo_id: "VENDOR-O-#{SecureRandom.hex(2)}", qbo_account: other_qa, data: { "display_name" => "Other Vendor" })
    shared_qbo_id = "SHARED#{SecureRandom.hex(2)}"
    QboBill.create!(qbo_id: shared_qbo_id, qbo_account: other_qa, qbo_vendor_id: vendor.qbo_id, data: {})
    # No row in Sanctuary's qbo_account with this id, so the Sanctuary stub finds nothing.
    stub = PayStub.create!(pay_cycle: @sanctuary_cycle, ledger: @sanctuary_ledger, amount: 100, blueprint: @blueprint, qbo_bill_id: shared_qbo_id)
    assert_nil stub.qbo_bill, "stub should NOT resolve to a bill in a different qbo_account"
  end

  test "sync_qbo_bill! is a no-op when enterprise has no qbo_account" do
    stub = PayStub.create!(pay_cycle: @other_cycle, ledger: @other_ledger, amount: 100, blueprint: @blueprint)
    # Should NOT raise and NOT set qbo_bill_id
    assert_nothing_raised { stub.sync_qbo_bill! }
    assert_nil stub.qbo_bill_id
  end

  test "sync_qbo_bill! is a no-op when contributor has no vendor mapping for the qbo_account" do
    # Sanctuary has qbo_account, but the contributor has no vendor mapping for it
    refute @contributor.qbo_vendor_for(@sanctuary_qa).present?
    stub = PayStub.create!(pay_cycle: @sanctuary_cycle, ledger: @sanctuary_ledger, amount: 100, blueprint: @blueprint)
    assert_nothing_raised { stub.sync_qbo_bill! }
    assert_nil stub.qbo_bill_id
  end
end

class SyncsAsQboBillFailureModeTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil

    @sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)
    @sanctuary_qa = @sanctuary.qbo_account || QboAccount.create!(
      enterprise: @sanctuary,
      client_id: "test_client_id",
      client_secret: "test_client_secret",
      realm_id: "test_realm_#{SecureRandom.hex(4)}",
    )

    @other_enterprise = Enterprise.find_or_create_by!(name: "FailMode-#{SecureRandom.hex(2)}")

    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "fm#{SecureRandom.hex(2)}@x.com", data: {})
    @contributor = Contributor.create!(forecast_person: fp)

    @sanctuary_ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @contributor)
    @other_ledger     = Ledger.find_or_create_for(enterprise: @other_enterprise, contributor: @contributor)

    @sanctuary_cycle = PayCycle.create!(enterprise: @sanctuary, starts_at: Date.new(2031, 1, 1), ends_at: Date.new(2031, 1, 31))
    @other_cycle     = PayCycle.create!(enterprise: @other_enterprise, starts_at: Date.new(2031, 1, 1), ends_at: Date.new(2031, 1, 31))

    @blueprint = { "lines" => [{ "amount" => 100.0, "hours" => 1, "rate" => 100, "forecast_project" => "x", "description" => "x" }] }

    # Wire up a vendor mapping so the amount-guard tests can hit that code path
    # rather than bailing out earlier at the missing-vendor check.
    @qbo_vendor = QboVendor.create!(
      qbo_id: "VENDOR-FM-#{SecureRandom.hex(2)}",
      qbo_account: @sanctuary_qa,
      data: { "display_name" => "FM Test Vendor" },
    )
    ContributorQboVendor.create!(
      contributor: @contributor,
      qbo_account: @sanctuary_qa,
      qbo_vendor: @qbo_vendor,
    )
  end

  # ---------------------------------------------------------------------------
  # sync_qbo_bill! amount guards
  # ---------------------------------------------------------------------------

  test "sync_qbo_bill! returns nil and creates no QboBill when amount is exactly zero" do
    stub = PayStub.create!(pay_cycle: @sanctuary_cycle, ledger: @sanctuary_ledger, amount: 100, blueprint: @blueprint)
    # Bypass amount_matches_blueprint_sum validator by writing directly to the DB.
    stub.update_columns(amount: 0)

    # If a QBO API call were made it would raise (no live credentials in tests).
    result = nil
    assert_nothing_raised { result = stub.sync_qbo_bill! }
    assert_nil result
    assert_nil stub.reload.qbo_bill_id
    assert_equal 0, QboBill.where(qbo_account_id: @sanctuary_qa.id).count
  end

  test "sync_qbo_bill! returns nil and creates no QboBill for negative amounts (ContributorAdjustment deduction fold)" do
    adj = ContributorAdjustment.create!(ledger: @sanctuary_ledger, amount: -50, effective_on: Date.new(2031, 1, 15), qbo_account: @sanctuary_qa)

    result = nil
    assert_nothing_raised { result = adj.sync_qbo_bill! }
    assert_nil result
    assert_nil adj.reload.qbo_bill_id
    assert_equal 0, QboBill.where(qbo_account_id: @sanctuary_qa.id).count
  end

  # ---------------------------------------------------------------------------
  # find_qbo_account! failure path
  # ---------------------------------------------------------------------------

  test "find_qbo_account! raises a descriptive error when enterprise has no qbo_account" do
    stub = PayStub.create!(pay_cycle: @other_cycle, ledger: @other_ledger, amount: 100, blueprint: @blueprint)
    err = assert_raises(RuntimeError) { stub.find_qbo_account! }
    assert_match(/has no connected QboAccount/, err.message)
  end

  # ---------------------------------------------------------------------------
  # load_qbo_bill! nil-return paths (no API call)
  # ---------------------------------------------------------------------------

  test "load_qbo_bill! returns nil when enterprise has no qbo_account even if qbo_bill_id is set" do
    stub = PayStub.create!(pay_cycle: @other_cycle, ledger: @other_ledger, amount: 100, blueprint: @blueprint)
    stub.update_columns(qbo_bill_id: "GHOST-#{SecureRandom.hex(4)}")

    # A live QBO call would raise; we expect a clean nil early-return instead.
    result = nil
    assert_nothing_raised { result = stub.load_qbo_bill! }
    assert_nil result
  end

  test "load_qbo_bill! returns nil when qbo_bill_id is blank" do
    stub = PayStub.create!(pay_cycle: @sanctuary_cycle, ledger: @sanctuary_ledger, amount: 100, blueprint: @blueprint)
    assert_nil stub.qbo_bill_id
    assert_nil stub.load_qbo_bill!
  end

  # ---------------------------------------------------------------------------
  # qbo_bill scope after the local row is removed
  # ---------------------------------------------------------------------------

  test "qbo_bill returns nil after the local QboBill record is removed" do
    bill = QboBill.create!(
      qbo_id: "DELBILL-#{SecureRandom.hex(2)}",
      qbo_account: @sanctuary_qa,
      qbo_vendor_id: @qbo_vendor.qbo_id,
      data: {},
    )
    stub = PayStub.create!(
      pay_cycle: @sanctuary_cycle,
      ledger: @sanctuary_ledger,
      amount: 100,
      blueprint: @blueprint,
      qbo_bill_id: bill.qbo_id,
    )
    assert_equal bill, stub.qbo_bill

    # Simulate the remote-gone cleanup: detach the stub's reference, then
    # delete the local QboBill row directly (bypassing before_destroy so
    # we don't attempt a live QBO API call in tests).
    stub.update_columns(qbo_bill_id: nil)
    QboBill.where(qbo_id: bill.qbo_id, qbo_account_id: @sanctuary_qa.id).delete_all

    assert_nil stub.reload.qbo_bill
  end

  # ---------------------------------------------------------------------------
  # detach_and_destroy_qbo_bill no-op when no bill exists
  # ---------------------------------------------------------------------------

  test "detach_and_destroy_qbo_bill is a no-op when qbo_bill_id is blank" do
    stub = PayStub.create!(pay_cycle: @sanctuary_cycle, ledger: @sanctuary_ledger, amount: 100, blueprint: @blueprint)
    assert_nil stub.qbo_bill_id
    assert_nothing_raised { stub.detach_and_destroy_qbo_bill }
    assert_nil stub.reload.qbo_bill_id
  end
end
