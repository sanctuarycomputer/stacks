require "test_helper"

class MsoTrueupTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 3, 1)

  def setup
    garden3d_qbo_account
    @report = mso_report(MONTH)
    @exec = mso_person("exec")
    @other = mso_person("other")
    @ledger = garden3d_ledger(@exec)
    @other_ledger = garden3d_ledger(@other)
    @role = mso_role(@exec)
    @other_role = mso_role(@other, tier: :principal)
    # Nothing here may reach QuickBooks.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
    Quickbooks::Service::Bill.any_instance.stubs(:create).raises(RuntimeError, "unexpected QuickBooks bill write")
  end

  def teardown
    clear_enterprise_memos
  end

  def payable?(trueup)
    MsoTrueup.find(trueup.id).payable?
  end

  # Accrual dating: March's true-up, synced and billed in July, is March's
  # income and its bill is dated 03/31.
  test "it is dated the last day of the report's month, whenever it was synced or billed" do
    trueup = mso_trueup(@report, @role, @ledger, amount: "1000")
    trueup.update_columns(created_at: Time.utc(2090, 7, 9), updated_at: Time.utc(2090, 7, 9))
    trueup = MsoTrueup.find(trueup.id)

    assert_equal Date.new(2090, 3, 31), @report.period.ends_at
    assert_equal Date.new(2090, 3, 31), trueup.payment_date
    assert_equal Date.new(2090, 3, 31), trueup.effective_on_for_display
    assert_equal Date.new(2090, 3, 31), trueup.bill_txn_date
  end

  test "its QuickBooks bill is tagged MT and described by its admin URL" do
    trueup = mso_trueup(@report, @role, @ledger, amount: "1000")

    assert_equal "MT", trueup.bill_doc_number_code
    assert_equal "https://stacks.garden3d.net/admin/ledgers/#{@ledger.id}/mso_trueups/#{trueup.id}",
      trueup.bill_description
  end

  test "an amount of zero or less, or no description, is invalid" do
    base = { ledger: @ledger, periodic_report: @report }

    assert_not MsoTrueup.new(base.merge(amount: 0, description: "x")).valid?
    assert_not MsoTrueup.new(base.merge(amount: -5, description: "x")).valid?
    assert_not MsoTrueup.new(base.merge(amount: 5, description: "")).valid?
    assert MsoTrueup.new(base.merge(amount: 5, description: "x")).valid?
  end

  test "it can only sit on a garden3d ledger" do
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: @exec)

    trueup = MsoTrueup.new(ledger: sanctuary_ledger, periodic_report: @report, amount: 5, description: "x")

    assert_not trueup.valid?
    assert_includes trueup.errors[:ledger], "must be a garden3d, LLC ledger"
  end

  test "one true-up per ledger per report" do
    mso_trueup(@report, @role, @ledger, amount: "1000")

    assert_raises(ActiveRecord::RecordNotUnique) { mso_trueup(@report, @role, @ledger, amount: "900") }
  end

  # payable? = every true-up on the report accepted AND the month's fee collected.
  test "payable? truth table: accepted x everyone accepted x fee collected" do
    mine = mso_trueup(@report, @role, @ledger, amount: "1000")
    theirs = mso_trueup(@report, @other_role, @other_ledger, amount: "2000")

    [
      # mine,  theirs, collected, payable
      [false, false, false, false],
      [true,  false, false, false],
      [false, true,  false, false],
      [true,  true,  false, false],
      [false, false, true,  false],
      [true,  false, true,  false],
      [false, true,  true,  false],
      [true,  true,  true,  true],
    ].each do |mine_accepted, theirs_accepted, collected, expected|
      mine.update_columns(accepted_at: mine_accepted ? Time.current : nil)
      theirs.update_columns(accepted_at: theirs_accepted ? Time.current : nil)
      fee_collected(MONTH, collected)

      assert_equal expected, payable?(mine),
        "mine=#{mine_accepted} theirs=#{theirs_accepted} collected=#{collected}"
    end
  end

  test "with no garden3d pass for the month, nothing is payable, and nothing is asked of a pass" do
    mine = mso_trueup(@report, @role, @ledger, amount: "1000", accepted: true)
    InvoicePass.any_instance.expects(:management_fee_collected?).never

    assert_nil InvoicePass.find_by(enterprise: garden3d, start_of_month: MONTH)
    assert_equal false, payable?(mine)
  end

  test "the fee is read from the stored invoice mirrors: uncollected, then collected" do
    pass = garden3d_pass(MONTH)
    tracker = fee_tracker(pass, make_payer("Truth Payer #{SecureRandom.hex(3)}"))
    attach_invoice(tracker, qbo_id: "8101", total: "500.0", balance: "500.0", sent: true)
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
    mine = mso_trueup(@report, @role, @ledger, amount: "1000", accepted: true)

    assert_equal false, payable?(mine)

    invoice = QboInvoice.find_by!(qbo_account_id: garden3d_qbo_account.id, qbo_id: "8101")
    invoice.update_columns(data: invoice.data.merge("balance" => "0.0"))

    assert_equal true, payable?(mine)
  end

  test "the fee question is asked once per report, however many true-ups ask" do
    fee_collected(MONTH)
    InvoicePass.any_instance.expects(:management_fee_collected?).once.returns(true)
    mso_trueup(@report, @role, @ledger, amount: "1000", accepted: true)
    mso_trueup(@report, @other_role, @other_ledger, amount: "2000", accepted: true)

    report = PeriodicReport.find(@report.id)

    assert_equal [true, true], report.mso_trueups.map(&:payable?)
  end

  test "acceptance toggles; a true-up with a QuickBooks bill cannot be un-accepted" do
    trueup = mso_trueup(@report, @role, @ledger, amount: "1000")

    trueup.toggle_acceptance!
    assert trueup.reload.accepted?
    trueup.toggle_acceptance!
    assert_not trueup.reload.accepted?

    trueup.update_columns(accepted_at: Time.current, qbo_bill_id: "77")
    assert trueup.locked?
    error = assert_raises(MsoTrueup::Locked) { trueup.toggle_acceptance! }
    assert_match(/QuickBooks bill/, error.message)
    assert trueup.reload.accepted?
  end

  # A sync that changed a billed true-up's amount cleared its acceptance. It
  # has to be acceptable again, or the month could never settle.
  test "an unaccepted true-up that has a bill can still be accepted" do
    trueup = mso_trueup(@report, @role, @ledger, amount: "1000")
    trueup.update_columns(qbo_bill_id: "77")

    assert_not trueup.locked?
    trueup.toggle_acceptance!

    assert trueup.reload.accepted?
  end

  test "sync_qbo_bill! refuses a true-up that is not payable, and writes nothing" do
    not_accepted = mso_trueup(@report, @role, @ledger, amount: "1000")
    fee_collected(MONTH)
    error = assert_raises(MsoTrueup::NotPayable) { not_accepted.sync_qbo_bill! }
    assert_match(/not payable/, error.message)

    not_accepted.update_columns(accepted_at: Time.current)
    fee_collected(MONTH, false)
    assert_raises(MsoTrueup::NotPayable) { MsoTrueup.find(not_accepted.id).sync_qbo_bill! }

    assert_nil not_accepted.reload.qbo_bill_id
    assert_equal 0, QboBill.where(qbo_account_id: garden3d_qbo_account.id).count
  end

  test "schema_ready? remembers yes, and while the answer is no asks the database at most once a minute" do
    MsoTrueup.instance_variable_set(:@schema_ready, nil)
    MsoTrueup.instance_variable_set(:@schema_checked_at, nil)
    MsoTrueup.connection.stubs(:data_source_exists?).returns(true) # any other table Rails asks about
    MsoTrueup.connection.expects(:data_source_exists?).with("mso_trueups").once.returns(false)

    assert_equal false, MsoTrueup.schema_ready?
    assert_equal false, MsoTrueup.schema_ready?
    assert_equal false, MsoTrueup.schema_ready?
  ensure
    MsoTrueup.instance_variable_set(:@schema_ready, true)
    MsoTrueup.instance_variable_set(:@schema_checked_at, nil)
  end

  test "deleting it takes its QuickBooks bill with it" do
    trueup = mso_trueup(@report, @role, @ledger, amount: "1000")
    trueup.expects(:detach_and_destroy_qbo_bill).once

    trueup.destroy

    assert_nil MsoTrueup.find_by(id: trueup.id)
    assert MsoTrueup.with_deleted.find(trueup.id).deleted_at.present?
  end
end
