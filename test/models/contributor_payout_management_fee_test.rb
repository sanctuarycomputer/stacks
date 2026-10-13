require "test_helper"

# A management fee invoice bills a paying company; nobody is paid out of it.
# The admin UI refuses to generate payouts for one, but a payout can also be
# made from the "new payout" form or the console, so the model refuses too.
class ContributorPayoutManagementFeeTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  REFUSAL = "Contributor Payouts cannot be made against one of garden3d's intercompany invoices.".freeze

  def setup
    garden3d_qbo_account
    @payer = make_payer("Fee Payer #{SecureRandom.hex(3)}")
    # In the payment-splits era, so only_after_new_deal has nothing to say.
    @pass = garden3d_pass(Date.new(2096, 4, 1))
    @creator = AdminUser.create!(email: "fee-payout-creator@example.com", password: "password12345", roles: ["admin"])
    person = ForecastPerson.create!(forecast_id: 941_001, email: "fee-payout-payee@example.com", data: {})
    person.ensure_contributor_exists!
    @ledger = Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: person.reload.contributor)
    # Any live sync would be a QuickBooks call.
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  def teardown
    clear_enterprise_memos
  end

  def payout_on(tracker, amount: 100.0)
    ContributorPayout.new(invoice_tracker: tracker, ledger: @ledger, amount: amount, created_by: @creator)
  end

  def sanctuary_tracker(blueprint: { "lines" => {} })
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    pass = InvoicePass.create!(start_of_month: Date.new(2096, 4, 1), enterprise: enterprises(:sanctuary), data: {})
    client = ForecastClient.create!(forecast_id: 941_002, name: "External Co")
    tracker = InvoiceTracker.create!(invoice_pass: pass, forecast_client_id: client.forecast_id,
                                     qbo_account: sanctuary_qa, blueprint: blueprint)
    attach_invoice(tracker, qbo_id: "sc-9", total: "1000.0", balance: "1000.0", sent: true)
  end

  test "a payout on a management fee tracker is invalid" do
    tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "fee-9", total: "130000.0", balance: "0.0", sent: true)
    assert tracker.garden3d?, "sanity"
    payout = payout_on(tracker)

    refute payout.valid?
    assert_includes payout.errors[:base], REFUSAL
    assert_raises(ActiveRecord::RecordInvalid) { payout.save! }
    assert_equal 0, ContributorPayout.where(invoice_tracker_id: tracker.id).count
  end

  test "the cap override does not let a payout onto a management fee tracker" do
    tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "fee-10", total: "130000.0", balance: "0.0", sent: true)
    payout = payout_on(tracker)
    payout.skip_seventy_percent_check = true

    refute payout.valid?
    assert_includes payout.errors[:base], REFUSAL
  end

  test "a payout on a management fee tracker with no invoice yet is invalid" do
    payout = payout_on(fee_tracker(@pass, @payer))

    refute payout.valid?
    assert_includes payout.errors[:base], REFUSAL
  end

  test "a payout already on a garden3d tracker can still be saved; a new one cannot be made" do
    # garden3d's seven 2025 passes each hold a Forecast tracker with payouts.
    tracker = attach_invoice(fee_tracker(@pass, @payer), qbo_id: "fee-11", total: "1000.0", balance: "1000.0", sent: true)
    tracker.update!(blueprint: { "lines" => {} })
    existing = payout_on(InvoiceTracker.find(tracker.id))
    existing.save!(validate: false)

    assert existing.reload.valid?, existing.errors.full_messages.join("; ")
    assert existing.update(description: "Still editable")
    refute payout_on(InvoiceTracker.find(tracker.id)).valid?
  end

  test "a payout on a Sanctuary tracker is valid" do
    payout = payout_on(sanctuary_tracker)

    assert payout.valid?, payout.errors.full_messages.join("; ")
    assert payout.save
  end

  test "a Sanctuary tracker with no blueprint is not a management fee tracker either" do
    payout = payout_on(sanctuary_tracker(blueprint: nil))

    payout.valid?

    refute_includes payout.errors[:base], REFUSAL
  end
end
