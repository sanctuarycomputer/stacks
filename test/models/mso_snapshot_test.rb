require "test_helper"

class MsoSnapshotTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2090, 4, 1)

  def setup
    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
  end

  def teardown
    clear_enterprise_memos
  end

  test "a pass has at most one current snapshot, and any number of superseded ones" do
    first = mso_snapshot(@pass)

    assert_raises(ActiveRecord::RecordNotUnique) { mso_snapshot(@pass) }

    first.update_columns(superseded_at: Time.current)
    second = mso_snapshot(@pass)
    first.update_columns(superseded_by_id: second.id)

    assert_equal [second.id], MsoSnapshot.current.where(invoice_pass_id: @pass.id).pluck(:id)
    assert_equal 2, InvoicePass.find(@pass.id).mso_snapshots.count
    assert_equal false, first.reload.current?
    assert_equal second, first.superseded_by
  end

  test "its figures can never be changed, but its stamps can" do
    snapshot = mso_snapshot(@pass)

    assert_not snapshot.update(fee_income: "1")
    assert_includes snapshot.errors[:base], "A snapshot's figures cannot be changed (fee_income); run the month again"
    assert_not MsoSnapshot.find(snapshot.id).update(lines: [{ "trueup" => "5.0" }])
    assert_not MsoSnapshot.find(snapshot.id).update(benchmark_average: "1.0")

    assert MsoSnapshot.find(snapshot.id).update(fee_collected_at: Time.current)
    assert_equal BigDecimal("100000"), snapshot.reload.fee_income
  end

  test "check_collection! asks QuickBooks once and stamps the answer" do
    snapshot = mso_snapshot(@pass)
    Mso::IntercompanyInvoices.expects(:collected?).with(invoice_pass: @pass).once.returns(true)

    assert_equal true, snapshot.check_collection!
    assert snapshot.reload.fee_collected?
  end

  test "check_collection! clears the stamp when the fee is no longer collected" do
    snapshot = mso_snapshot(@pass, collected: true)
    Mso::IntercompanyInvoices.expects(:collected?).with(invoice_pass: @pass).once.returns(false)

    assert_equal false, snapshot.check_collection!
    assert_not snapshot.reload.fee_collected?
  end

  test "check_collection! refuses a superseded snapshot without asking QuickBooks" do
    snapshot = mso_snapshot(@pass)
    snapshot.update_columns(superseded_at: Time.current)
    Mso::IntercompanyInvoices.stubs(:collected?).raises(RuntimeError, "unexpected QuickBooks read")

    error = assert_raises(MsoSnapshot::Unusable) { snapshot.check_collection! }
    assert_match(/superseded/, error.message)
  end

  test "invalidating records why and withdraws the collection stamp; the figures stay as they were" do
    snapshot = mso_snapshot(@pass, collected: true)

    snapshot.invalidate!("Account 4100 now reads 90000.0")

    snapshot.reload
    assert snapshot.invalidated?
    assert_equal "Account 4100 now reads 90000.0", snapshot.invalidated_reason
    assert_not snapshot.fee_collected?
    assert snapshot.current?
    assert_equal BigDecimal("100000"), snapshot.fee_income
  end

  test "unconfirm_collection! withdraws the stamp on the pass's current snapshot only" do
    old = mso_snapshot(@pass, collected: true)
    old.update_columns(superseded_at: Time.current)
    current = mso_snapshot(@pass, collected: true)
    elsewhere = mso_snapshot(garden3d_pass(Date.new(2090, 5, 1)), collected: true)

    assert_equal 1, MsoSnapshot.unconfirm_collection!(@pass.id)

    assert_not current.reload.fee_collected?
    assert old.reload.fee_collected?
    assert elsewhere.reload.fee_collected?
    assert_equal false, current.over_cap?
  end
end
