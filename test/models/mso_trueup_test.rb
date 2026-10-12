require "test_helper"

class MsoTrueupTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 3, 1)

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @exec = mso_person("exec")
    @other = mso_person("other")
    @ledger = garden3d_ledger(@exec)
    @other_ledger = garden3d_ledger(@other)
    @role = mso_role(@exec)
    @other_role = mso_role(@other, tier: :principal)
    # Nothing here may reach QuickBooks unless a test says so.
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
  end

  def teardown
    clear_enterprise_memos
  end

  def snapshot(lines: nil, collected: true)
    lines ||= [mso_line(@role, @ledger, trueup: "1000.0")]
    mso_snapshot(@pass, lines: lines, collected: collected)
  end

  # Accrual dating (owner decision O2): March's true-up, run and billed in
  # July, is March's income and its bill is dated 03/31.
  test "it is dated the last day of the fee month, whenever it was run or billed" do
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")
    trueup.update_columns(created_at: Time.utc(2090, 7, 9), updated_at: Time.utc(2090, 7, 9))
    trueup = MsoTrueup.find(trueup.id)

    assert_equal Date.new(2090, 3, 31), trueup.payment_date
    assert_equal Date.new(2090, 3, 31), trueup.effective_on_for_display
    assert_equal Date.new(2090, 3, 31), trueup.bill_txn_date
    # (That it then counts as March's income, not July's, is Task 2's test.)
  end

  test "its QuickBooks bill is tagged MT and described by its admin URL" do
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")

    assert_equal "MT", trueup.bill_doc_number_code
    assert_equal "https://stacks.garden3d.net/admin/ledgers/#{@ledger.id}/mso_trueups/#{trueup.id}",
      trueup.bill_description
  end

  test "an amount of zero or less, or no description, is invalid" do
    base = { ledger: @ledger, invoice_pass: @pass, mso_snapshot: snapshot, mso_role_period: @role }

    assert_not MsoTrueup.new(base.merge(amount: 0, description: "x")).valid?
    assert_not MsoTrueup.new(base.merge(amount: -5, description: "x")).valid?
    assert_not MsoTrueup.new(base.merge(amount: 5, description: "")).valid?
    assert MsoTrueup.new(base.merge(amount: 5, description: "x")).valid?
  end

  test "it can only sit on a garden3d ledger and garden3d's pass" do
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: enterprises(:sanctuary), contributor: @exec)
    snap = snapshot

    on_wrong_ledger = MsoTrueup.new(ledger: sanctuary_ledger, invoice_pass: @pass, mso_snapshot: snap,
                                    mso_role_period: @role, amount: 5, description: "x")
    on_wrong_pass = MsoTrueup.new(ledger: @ledger, invoice_pass: snap.sanctuary_invoice_pass, mso_snapshot: snap,
                                  mso_role_period: @role, amount: 5, description: "x")

    assert_not on_wrong_ledger.valid?
    assert_includes on_wrong_ledger.errors[:ledger], "must be a garden3d, LLC ledger"
    assert_not on_wrong_pass.valid?
    assert_includes on_wrong_pass.errors[:invoice_pass], "must be garden3d, LLC's pass"
  end

  test "one live true-up per ledger per pass, and a soft-deleted one does not block another" do
    snap = snapshot
    first = mso_trueup(snap, @role, @ledger, amount: "1000")

    assert_raises(ActiveRecord::RecordNotUnique) { mso_trueup(snap, @role, @ledger, amount: "900") }

    first.destroy
    assert_nothing_raised { mso_trueup(snap, @role, @ledger, amount: "900") }
    assert_equal 2, MsoTrueup.with_deleted.where(ledger_id: @ledger.id, invoice_pass_id: @pass.id).count
  end

  test "it is not payable until it is accepted" do
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")

    assert_equal false, trueup.payable?
    trueup.toggle_acceptance!
    assert_equal true, MsoTrueup.find(trueup.id).payable?
  end

  test "it is not payable until the fee is confirmed collected" do
    snap = snapshot(collected: false)
    trueup = mso_trueup(snap, @role, @ledger, amount: "1000", accepted: true)

    assert_equal false, trueup.payable?
    snap.update_columns(fee_collected_at: Time.current)
    assert_equal true, MsoTrueup.find(trueup.id).payable?
  end

  test "it is not payable until every expected true-up is accepted, including one that does not exist yet" do
    snap = snapshot(lines: [mso_line(@role, @ledger, trueup: "1000.0"),
                            mso_line(@other_role, @other_ledger, trueup: "2000.0")])
    mine = mso_trueup(snap, @role, @ledger, amount: "1000", accepted: true)

    # The other executive's row has not been created: 1 of 1 accepted is not 2 of 2.
    assert_equal false, mine.payable?

    theirs = mso_trueup(snap, @other_role, @other_ledger, amount: "2000")
    assert_equal false, MsoTrueup.find(mine.id).payable?

    theirs.toggle_acceptance!
    assert_equal true, MsoTrueup.find(mine.id).payable?
  end

  test "a line with a zero true-up expects no row" do
    snap = snapshot(lines: [mso_line(@role, @ledger, trueup: "1000.0"),
                            mso_line(@other_role, @other_ledger, trueup: "0.0")])
    mine = mso_trueup(snap, @role, @ledger, amount: "1000", accepted: true)

    assert_equal [@ledger.id], snap.expected_ledger_ids
    assert_equal true, mine.payable?
  end

  test "it is not payable once its snapshot has been superseded" do
    snap = snapshot
    trueup = mso_trueup(snap, @role, @ledger, amount: "1000", accepted: true)
    assert_equal true, trueup.payable?

    snap.update_columns(superseded_at: Time.current)
    assert_equal false, MsoTrueup.find(trueup.id).payable?
  end

  test "acceptance toggles, and is refused once a QuickBooks bill exists" do
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")

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

  test "sync_qbo_bill! refuses a true-up that is not payable, before any QuickBooks call" do
    trueup = mso_trueup(snapshot(collected: false), @role, @ledger, amount: "1000", accepted: true)
    Quickbooks::Service::Bill.any_instance.stubs(:create).raises(RuntimeError, "unexpected QuickBooks bill write")

    error = assert_raises(MsoTrueup::NotPayable) { trueup.sync_qbo_bill! }
    assert_match(/not payable/, error.message)
    assert_nil trueup.reload.qbo_bill_id
  end

  test "a billed true-up counts as payable whatever else has changed" do
    snap = snapshot(collected: false)
    trueup = mso_trueup(snap, @role, @ledger, amount: "1000")
    assert_equal false, trueup.payable?

    trueup.update_columns(qbo_bill_id: "77")

    assert_equal true, MsoTrueup.find(trueup.id).payable?
  end

  test "it is not payable while its snapshot is invalidated, and confirming collection cannot bring it back" do
    snap = snapshot
    trueup = mso_trueup(snap, @role, @ledger, amount: "1000", accepted: true)
    assert_equal true, trueup.payable?

    snap.invalidate!("a later run was refused")

    assert_equal false, MsoTrueup.find(trueup.id).payable?
    Mso::ManagementFeeInvoices.stubs(:collected?).raises(RuntimeError, "unexpected QuickBooks read")
    error = assert_raises(MsoSnapshot::Unusable) { MsoSnapshot.find(snap.id).check_collection! }
    assert_match(/a later run was refused/, error.message)
    assert_equal false, MsoTrueup.find(trueup.id).payable?
  end

  test "accepting is refused when the amount is no longer the one the person saw" do
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")

    error = assert_raises(MsoTrueup::AmountChanged) { trueup.toggle_acceptance!(expected_amount: "999.99") }
    assert_match(/1000\.0/, error.message)
    assert_raises(MsoTrueup::AmountChanged) { trueup.toggle_acceptance!(expected_amount: "not a number") }
    assert_not trueup.reload.accepted?

    trueup.toggle_acceptance!(expected_amount: "1000.0")
    assert trueup.reload.accepted?
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
    trueup = mso_trueup(snapshot, @role, @ledger, amount: "1000")
    trueup.expects(:detach_and_destroy_qbo_bill).once

    trueup.destroy

    assert_nil MsoTrueup.find_by(id: trueup.id)
    assert MsoTrueup.with_deleted.find(trueup.id).deleted_at.present?
  end
end
