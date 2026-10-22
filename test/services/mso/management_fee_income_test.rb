require "test_helper"

class Mso::ManagementFeeIncomeTest < ActiveSupport::TestCase
  include ManagementFeeFixtures

  MONTH = Date.new(2092, 6, 1)

  def setup
    @qbo_account = garden3d_qbo_account
    # Nothing here may fetch a report or sync an invoice unless a test says so.
    QboProfitAndLossReport.stubs(:find_or_fetch_for_range).raises(RuntimeError, "unexpected QuickBooks read")
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
  end

  def teardown
    clear_enterprise_memos
  end

  def report!(accrual_rows, cash_rows: [], qbo_account: @qbo_account, month: MONTH)
    QboProfitAndLossReport.create!(
      qbo_account: qbo_account, starts_at: month, ends_at: month.end_of_month,
      data: { cash: { rows: cash_rows }, accrual: { rows: accrual_rows } },
    )
  end

  def fee_rows(amount)
    [["4100 Management Fee Income", amount], ["Total Income", amount], ["Net Income", amount]]
  end

  # --- for_month -------------------------------------------------------------

  test "it reads the accrual 4100 row as a BigDecimal" do
    report!(fee_rows("130000.0"), cash_rows: fee_rows("5.0"))

    income = Mso::ManagementFeeIncome.for_month(MONTH)

    assert_kind_of BigDecimal, income
    assert_equal BigDecimal("130000"), income
  end

  test "any date in the month reads that month" do
    report!(fee_rows("170000.0"))

    assert_equal BigDecimal("170000"), Mso::ManagementFeeIncome.for_month(Date.new(2092, 6, 17))
  end

  test "a missing row raises instead of reading as zero" do
    report!([["Total Income", nil], ["6100 Platform Infrastructure", "250.0"]])

    error = assert_raises(Mso::ManagementFeeIncome::RowMissing) { Mso::ManagementFeeIncome.for_month(MONTH) }

    assert_match(/June 2092/, error.message)
  end

  test "a genuine zero is zero, not a missing row" do
    report!(fee_rows("0.0"))

    assert_equal BigDecimal("0"), Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "the match is on the account number, so a renamed account still reads" do
    report!([["4100 Mgmt Fees (renamed)", "140000.0"], ["Total Income", "140000.0"]])

    assert_equal BigDecimal("140000"), Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "a total row and a longer account number do not match" do
    report!([["Total 4100 Management Fee Income", "1.0"], ["41000 Something Else", "2.0"]])

    assert_raises(Mso::ManagementFeeIncome::RowMissing) { Mso::ManagementFeeIncome.for_month(MONTH) }
  end

  test "two rows starting with 4100 raise rather than guess" do
    report!([["4100 Management Fee Income", "100.0"], ["4100.1 Sub-account", "50.0"]])

    error = assert_raises(Mso::ManagementFeeIncome::RowMissing) { Mso::ManagementFeeIncome.for_month(MONTH) }

    assert_match(/2 rows/, error.message)
  end

  test "a row with no amount raises" do
    report!([["4100 Management Fee Income", nil]])

    assert_raises(Mso::ManagementFeeIncome::RowMissing) { Mso::ManagementFeeIncome.for_month(MONTH) }
  end

  test "an amount that is not a number raises this reader's own error, not a bare ArgumentError" do
    report!([["4100 Management Fee Income", "1,300.00 USD"]])

    error = assert_raises(Mso::ManagementFeeIncome::MalformedRow) { Mso::ManagementFeeIncome.for_month(MONTH) }

    assert_kind_of Mso::ManagementFeeIncome::Error, error
    assert_match(/1,300\.00 USD/, error.message)
  end

  test "it reads garden3d's report, never Sanctuary's" do
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    report!(fee_rows("999999.0"), qbo_account: sanctuary_qa)
    report!(fee_rows("130000.0"))

    assert_equal BigDecimal("130000"), Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "with duplicate stored reports it reads the newest" do
    report!(fee_rows("100.0"))
    report!(fee_rows("130000.0"))

    assert_equal BigDecimal("130000"), Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "a stored report is never re-fetched" do
    report!(fee_rows("130000.0"))
    QboProfitAndLossReport.expects(:find_or_fetch_for_range).never

    Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "with nothing stored it fetches once, and never with force" do
    fetched = QboProfitAndLossReport.new(data: { "accrual" => { "rows" => fee_rows("130000.0") } })
    # force is the THIRD POSITIONAL argument. `true` there deletes stored rows.
    QboProfitAndLossReport.expects(:find_or_fetch_for_range).once
      .with(MONTH, MONTH.end_of_month, false, @qbo_account)
      .returns(fetched)

    assert_equal BigDecimal("130000"), Mso::ManagementFeeIncome.for_month(MONTH)
  end

  test "it raises when garden3d has no QuickBooks account" do
    QboAccount.where(enterprise_id: garden3d.id).delete_all

    error = assert_raises(Mso::ManagementFeeIncome::Error) { Mso::ManagementFeeIncome.for_month(MONTH) }

    assert_match(/no connected QboAccount/, error.message)
  end

  # --- reconcile -------------------------------------------------------------

  def payer_with_invoice(pass, forecast_id:, qbo_id:, lines:)
    payer = make_payer("Reconcile Payer #{forecast_id}", forecast_ids: [forecast_id])
    total = lines.sum(BigDecimal("0")) { |line| BigDecimal(line["amount"]) }.to_s("F")
    attach_invoice(fee_tracker(pass, payer), qbo_id: qbo_id, total: total, balance: total, sent: true, lines: lines)
  end

  test "reconcile reports no variance when the fee lines equal account 4100" do
    report!(fee_rows("170000.0"))
    pass = garden3d_pass(MONTH)
    payer_with_invoice(pass, forecast_id: 991_001, qbo_id: "r-1", lines: [fee_line("130000.0")])
    payer_with_invoice(pass, forecast_id: 991_002, qbo_id: "r-2", lines: [fee_line("40000.0")])

    result = Mso::ManagementFeeIncome.reconcile(MONTH)

    assert_equal BigDecimal("170000"), result[:account_total]
    assert_equal BigDecimal("170000"), result[:payer_total]
    assert_equal BigDecimal("0"), result[:variance]
    result.slice(:account_total, :payer_total, :variance).each_value { |value| assert_kind_of BigDecimal, value }
  end

  test "reconcile counts only Managerial Services lines, so a loan repayment line is not fee income" do
    report!(fee_rows("130000.0"))
    pass = garden3d_pass(MONTH)
    payer_with_invoice(pass, forecast_id: 991_003, qbo_id: "r-3",
                       lines: [fee_line("130000.0"), fee_line("25000.0", item: "Loan Repayment")])

    result = Mso::ManagementFeeIncome.reconcile(MONTH)

    assert_equal BigDecimal("130000"), result[:payer_total]
    assert_equal BigDecimal("0"), result[:variance]
  end

  test "reconcile reports the variance when account 4100 holds income no payer was invoiced for" do
    # A $30,000 advisory fee to an outside customer, booked to the same account.
    report!(fee_rows("160000.0"))
    pass = garden3d_pass(MONTH)
    payer_with_invoice(pass, forecast_id: 991_004, qbo_id: "r-4", lines: [fee_line("130000.0")])

    result = Mso::ManagementFeeIncome.reconcile(MONTH)

    assert_equal BigDecimal("30000"), result[:variance]
  end

  test "the breakdown shows which invoice's fee line is on the wrong item" do
    # Finance billed the fee on the default Services item. It posts to 4100,
    # so the account has it, but it is not a Managerial Services line.
    report!(fee_rows("170000.0"))
    pass = garden3d_pass(MONTH)
    good = payer_with_invoice(pass, forecast_id: 991_008, qbo_id: "r-8", lines: [fee_line("130000.0")])
    wrong = payer_with_invoice(pass, forecast_id: 991_009, qbo_id: "r-9",
                               lines: [fee_line("40000.0", item: "Services")])

    result = Mso::ManagementFeeIncome.reconcile(MONTH)

    assert_equal BigDecimal("40000"), result[:variance]
    assert_equal [
      { tracker_id: good.id, qbo_id: "r-8", total: BigDecimal("130000"), managerial_services: BigDecimal("130000") },
      { tracker_id: wrong.id, qbo_id: "r-9", total: BigDecimal("40000"), managerial_services: BigDecimal("0") },
    ], result[:invoices]
  end

  test "reconcile with no garden3d pass for the month has a payer total of zero" do
    report!(fee_rows("130000.0"))

    result = Mso::ManagementFeeIncome.reconcile(MONTH)

    assert_equal BigDecimal("0"), result[:payer_total]
    assert_equal BigDecimal("130000"), result[:variance]
    assert_equal [], result[:invoices]
  end

  test "reconcile refuses an invoice that has never been synced, without syncing it" do
    report!(fee_rows("130000.0"))
    pass = garden3d_pass(MONTH)
    payer = make_payer("Unsynced Payer", forecast_ids: [991_005])
    tracker = fee_tracker(pass, payer)
    QboInvoice.create!(qbo_account: @qbo_account, qbo_id: "r-5", data: {})
    tracker.update!(qbo_invoice_id: "r-5")

    error = assert_raises(Mso::ManagementFeeIncome::UnsyncedInvoice) { Mso::ManagementFeeIncome.reconcile(MONTH) }

    assert_match(/r-5/, error.message)
  end

  test "reconcile refuses a tracker that has been pointed at another company's QuickBooks account" do
    # The tracker edit form can attach an invoice from any account, which
    # re-points qbo_account_id along with it.
    report!(fee_rows("130000.0"))
    pass = garden3d_pass(MONTH)
    payer = make_payer("Repointed Payer", forecast_ids: [991_010])
    tracker = fee_tracker(pass, payer)
    sanctuary_qa = Enterprise.find(enterprises(:sanctuary).id).qbo_account
    QboInvoice.create!(qbo_account: sanctuary_qa, qbo_id: "r-10",
                       data: { "total" => "130000.0", "balance" => "0.0", "line_items" => [fee_line("130000.0")] })
    tracker.update!(qbo_account: sanctuary_qa, qbo_invoice_id: "r-10")

    error = assert_raises(Mso::ManagementFeeIncome::WrongAccount) { Mso::ManagementFeeIncome.reconcile(MONTH) }

    assert_match(/InvoiceTracker #{tracker.id}/, error.message)
  end

  test "reconcile! raises on a variance and returns the figures when there is none" do
    report!(fee_rows("160000.0"))
    pass = garden3d_pass(MONTH)
    payer_with_invoice(pass, forecast_id: 991_006, qbo_id: "r-6", lines: [fee_line("130000.0")])

    error = assert_raises(Mso::ManagementFeeIncome::VarianceError) { Mso::ManagementFeeIncome.reconcile!(MONTH) }
    assert_match(/30000/, error.message)
    assert_match(/r-6/, error.message, "the error names the invoices it compared")

    payer_with_invoice(pass, forecast_id: 991_007, qbo_id: "r-7", lines: [fee_line("30000.0")])
    assert_equal BigDecimal("0"), Mso::ManagementFeeIncome.reconcile!(MONTH)[:variance]
  end
end
