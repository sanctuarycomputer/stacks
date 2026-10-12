require "test_helper"

class Mso::MonthlyRunTest < ActiveSupport::TestCase
  include MsoFixtures

  MONTH = Date.new(2093, 5, 1)
  TODAY = Date.new(2093, 6, 10)

  def setup
    @sanctuary = enterprises(:sanctuary)
    @sanctuary_pass = sanctuary_pass(MONTH)
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "Run Client #{SecureRandom.hex(3)}")
    @tracker = InvoiceTracker.create!(invoice_pass: @sanctuary_pass, forecast_client: client,
                                      qbo_account: Enterprise.find(@sanctuary.id).qbo_account)

    garden3d_qbo_account
    @pass = garden3d_pass(MONTH)
    @payer = make_payer("Run Payer #{SecureRandom.hex(3)}", customer_id: "2")
    @fee_tracker = fee_tracker(@pass, @payer)
    charge_fee("100000.0")

    # Sanctuary's top three: 30,000 / 20,000 / 10,000, so the benchmark is 20,000.
    @top = earner("a", 30_000)
    earner("b", 20_000)
    earner("c", 10_000)

    @chief = mso_person("chief")
    @chief_role = mso_role(@chief, tier: :chief, title: "Operations")
    @principal = mso_person("principal")
    @principal_role = mso_role(@principal, tier: :principal, title: "Founder")

    # The one QuickBooks-touching call a run makes. Everything else raises.
    Mso::ManagementFeeInvoices.stubs(:collected?).returns(true)
    QboProfitAndLossReport.stubs(:find_or_fetch_for_range).raises(RuntimeError, "unexpected QuickBooks read")
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
  end

  def teardown
    clear_enterprise_memos
  end

  # garden3d's fee for MONTH: one paid invoice and a matching 4100 row.
  def charge_fee(amount, account_total: amount)
    QboInvoice.where(qbo_account_id: garden3d_qbo_account.id, qbo_id: "9001").delete_all
    QboProfitAndLossReport.where(qbo_account_id: garden3d_qbo_account.id, starts_at: MONTH).delete_all
    # A fresh copy of the tracker: where the database carries the composite
    # foreign key to qbo_invoices, deleting the mirror above nulls the
    # tracker's qbo_invoice_id, and a stale copy would not re-attach it.
    attach_invoice(InvoiceTracker.find(@fee_tracker.id), qbo_id: "9001", total: amount, balance: "0.0", sent: true)
    fee_report(MONTH, account_total)
  end

  # Saved without validation: these tests are about who earned what, not
  # about ContributorPayout's own invoice-share rules.
  def pay(contributor, amount, enterprise: @sanctuary, tracker: @tracker)
    ledger = Ledger.find_or_create_for(enterprise: enterprise, contributor: contributor)
    payout = ContributorPayout.new(ledger: ledger, invoice_tracker: tracker, created_by: mso_admin, amount: amount)
    payout.save!(validate: false)
    payout
  end

  def earner(tag, amount)
    mso_person("earner-#{tag}").tap { |contributor| pay(contributor, amount) }
  end

  def run!(pass: @pass, today: TODAY, **opts)
    Mso::MonthlyRun.call(invoice_pass: pass, today: today, **opts)
  end

  def trueup_for(contributor)
    MsoTrueup.find_by(invoice_pass_id: @pass.id, ledger_id: garden3d_ledger(contributor).id)
  end

  def line_for(snapshot, contributor)
    snapshot.lines.find { |line| line["contributor_id"] == contributor.id }
  end

  def refused(pass: @pass, today: TODAY)
    assert_raises(Mso::MonthlyRun::Refused) { run!(pass: pass, today: today) }
  end

  def assert_nothing_written
    assert_equal 0, MsoSnapshot.where(invoice_pass_id: @pass.id).count
    assert_equal 0, MsoTrueup.with_deleted.where(invoice_pass_id: @pass.id).count
  end

  # --- what a run records -----------------------------------------------------

  test "the snapshot records every input and output of the run" do
    snapshot = run!(run_by: mso_admin)

    assert snapshot.current?
    assert_equal @pass.id, snapshot.invoice_pass_id
    assert_equal @sanctuary_pass.id, snapshot.sanctuary_invoice_pass_id
    assert_equal mso_admin, snapshot.created_by
    assert_equal BigDecimal("100000"), snapshot.fee_income
    assert_equal "20000.0", snapshot.benchmark_average
    assert_equal [3, 3, false], [snapshot.configured_n, snapshot.counted, snapshot.small_sample]
    assert_equal %w[30000.0 20000.0 10000.0], snapshot.benchmark_members.map { |member| member["amount"] }
    assert_equal [], snapshot.excluded_without_login
    assert_equal BigDecimal("0.55"), snapshot.cap_percentage
    assert_equal BigDecimal("55000"), snapshot.cap
    assert_equal "43000.0", snapshot.total_calculated
    assert_equal BigDecimal("43000"), snapshot.total_trueup
    assert_equal BigDecimal("43000"), snapshot.total_trueup_as_billed
    assert_not snapshot.over_cap?
    assert_not snapshot.invalidated?
    assert_equal "0.0", snapshot.reconciliation["variance"]
    assert_equal ["9001"], snapshot.reconciliation["invoices"].map { |invoice| invoice["qbo_id"] }
    assert_equal [], snapshot.drift
    assert snapshot.fee_collected?

    assert_equal(
      {
        "mso_role_period_id" => @principal_role.id, "contributor_id" => @principal.id,
        "ledger_id" => garden3d_ledger(@principal).id, "tier" => "principal", "title" => "Founder",
        "multiplier" => "1.15", "started_at" => "2090-01-01", "ended_at" => nil,
        "already_earned" => "0.0", "earned_by_ledger" => {},
        "calculated" => "23000.0", "final" => "23000.0", "reduction" => "0.0", "trueup" => "23000.0",
        "trueup_before_rounding" => "23000.0"
      },
      line_for(snapshot, @principal),
    )
    assert_equal 2, snapshot.lines.size
  end

  test "each executive gets one unaccepted true-up on their garden3d ledger" do
    snapshot = run!

    chief = trueup_for(@chief)
    principal = trueup_for(@principal)
    assert_equal [BigDecimal("20000"), BigDecimal("23000")], [chief.amount, principal.amount]
    assert_equal [false, false], [chief.accepted?, principal.accepted?]
    assert_equal [snapshot.id, snapshot.id], [chief.mso_snapshot_id, principal.mso_snapshot_id]
    assert_equal @chief_role.id, chief.mso_role_period_id
    assert_equal garden3d.id, chief.ledger.enterprise_id
    assert_equal Date.new(2093, 5, 31), chief.payment_date
    assert_match(/MSO true-up for May 2093/, chief.description)
    assert_match(/Chief \(Operations\), 1\.0x/, chief.description)
    assert_match(/\$20,000\.00/, chief.description)
    assert_equal 2, MsoTrueup.where(invoice_pass_id: @pass.id).count
  end

  test "the benchmark average is stored unrounded" do
    pay(@top, "0.01") # the top three now total 60,000.01

    snapshot = run!

    live = Mso::Benchmark.for_month(MONTH).average
    assert_equal live, BigDecimal(snapshot.benchmark_average)
    assert_match(/\A20000\.003333333/, snapshot.benchmark_average)
    assert_match(/\A20000\.003333333/, line_for(snapshot, @chief)["calculated"])
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount
  end

  test "what a person already earned is netted across all their ledgers" do
    pay(@chief, 5_000)
    pay(@chief, 2_000, enterprise: enterprises(:one))

    snapshot = run!

    line = line_for(snapshot, @chief)
    assert_equal "7000.0", line["already_earned"]
    assert_equal(
      {
        Ledger.find_by!(enterprise: @sanctuary, contributor: @chief).id.to_s => "5000.0",
        Ledger.find_by!(enterprise: enterprises(:one), contributor: @chief).id.to_s => "2000.0",
      },
      line["earned_by_ledger"],
    )
    assert_equal BigDecimal("13000"), trueup_for(@chief).amount
    # The cap is a ceiling: one person's earnings change nobody else's true-up.
    assert_equal BigDecimal("23000"), trueup_for(@principal).amount
  end

  test "someone who out-earned their target gets no true-up, no clawback and no row" do
    pay(@chief, 25_000)

    snapshot = run!

    assert_nil trueup_for(@chief)
    line = line_for(snapshot, @chief)
    assert_equal ["20000.0", "0.0"], [line["final"], line["trueup"]]
    assert_equal [garden3d_ledger(@principal).id], snapshot.expected_ledger_ids
    assert_equal BigDecimal("23000"), snapshot.total_trueup
  end

  test "over the cap, every line is reduced pro rata and the true-ups sum to the cap exactly" do
    charge_fee("60000.0") # cap 33,000 against 43,000 calculated

    snapshot = run!

    assert_equal BigDecimal("33000"), snapshot.cap
    assert_equal [BigDecimal("15348.84"), BigDecimal("17651.16")],
      [trueup_for(@chief).amount, trueup_for(@principal).amount]
    assert_equal "4651.16", line_for(snapshot, @chief)["reduction"]
    assert_equal BigDecimal("33000"), snapshot.total_trueup
  end

  test "once everyone accepts, the true-ups are payable" do
    run!
    chief = trueup_for(@chief)
    chief.toggle_acceptance!

    assert_equal false, MsoTrueup.find(chief.id).payable?

    trueup_for(@principal).toggle_acceptance!

    assert_equal true, MsoTrueup.find(chief.id).payable?
  end

  # --- running a month again ----------------------------------------------------

  test "running an unchanged month again does not net a true-up against itself" do
    run!
    first = trueup_for(@chief)

    snapshot = run!

    again = trueup_for(@chief)
    assert_equal first.id, again.id
    assert_equal BigDecimal("20000"), again.amount
    assert_equal "0.0", line_for(snapshot, @chief)["already_earned"]
  end

  test "a re-run supersedes the snapshot and keeps the old one's figures" do
    first = run!
    first_lines = first.lines.deep_dup
    pay(@chief, 1_000)

    second = run!

    first.reload
    assert_not first.current?
    assert_equal second, first.superseded_by
    assert_equal first_lines, first.lines
    assert_equal "20000.0", line_for(first, @chief)["trueup"]
    assert_equal "19000.0", line_for(second, @chief)["trueup"]
    assert_equal [second.id], MsoSnapshot.current.where(invoice_pass_id: @pass.id).pluck(:id)
    assert_equal second.id, trueup_for(@chief).mso_snapshot_id
    assert_equal second.id, trueup_for(@principal).mso_snapshot_id
  end

  test "an acceptance survives a re-run that leaves the amount alone, and is cleared by one that changes it" do
    run!
    trueup_for(@chief).toggle_acceptance!
    trueup_for(@principal).toggle_acceptance!

    run!
    assert trueup_for(@chief).accepted?
    assert trueup_for(@principal).accepted?

    pay(@chief, 1_000)
    run!

    chief = trueup_for(@chief)
    assert_equal BigDecimal("19000"), chief.amount
    assert_not chief.accepted?
    assert trueup_for(@principal).accepted?
  end

  test "a true-up with a QuickBooks bill is never altered; the difference is recorded as drift" do
    run!
    locked = trueup_for(@chief)
    locked.update_columns(accepted_at: Time.current, qbo_bill_id: "88")
    pay(@chief, 1_000)

    snapshot = run!

    locked.reload
    assert_equal BigDecimal("20000"), locked.amount
    assert locked.accepted?
    assert_equal "88", locked.qbo_bill_id
    assert_equal snapshot.id, locked.mso_snapshot_id
    assert_equal "19000.0", line_for(snapshot, @chief)["trueup"]
    assert_equal [{ "mso_trueup_id" => locked.id, "ledger_id" => locked.ledger_id,
                    "billed_amount" => "20000.0", "computed_amount" => "19000.0" }], snapshot.drift

    # And a locked true-up is not removed when its executive leaves the roster.
    @chief_role.update!(ended_at: Date.new(2093, 4, 30))
    after_leaving = run!
    assert_equal BigDecimal("20000"), MsoTrueup.find(locked.id).amount
    assert_equal ["0.0"], after_leaving.drift.map { |entry| entry["computed_amount"] }
  end

  test "a true-up no longer owed is removed, and comes back as the same row if it is owed again" do
    run!
    original = trueup_for(@chief)
    original.toggle_acceptance!
    @chief_role.update!(ended_at: Date.new(2093, 4, 30))

    without = run!

    assert_nil trueup_for(@chief)
    assert MsoTrueup.with_deleted.find(original.id).deleted_at.present?
    assert_equal [@principal.id], without.lines.map { |line| line["contributor_id"] }

    @chief_role.update!(ended_at: nil)
    run!

    restored = trueup_for(@chief)
    assert_equal original.id, restored.id
    assert_nil restored.deleted_at
    assert_equal BigDecimal("20000"), restored.amount
    assert_not restored.accepted?, "a restored true-up must be accepted afresh"
    assert_equal 2, MsoTrueup.with_deleted.where(invoice_pass_id: @pass.id).count
  end

  test "a restored true-up never comes back carrying a QuickBooks bill id" do
    run!
    original = trueup_for(@chief)
    @chief_role.update!(ended_at: Date.new(2093, 4, 30))
    run!
    # However it got there: a soft-deleted row that still names a bill.
    MsoTrueup.with_deleted.where(id: original.id).update_all(qbo_bill_id: "77", accepted_at: Time.current)
    @chief_role.update!(ended_at: nil)

    snapshot = run!

    restored = trueup_for(@chief)
    assert_equal original.id, restored.id
    assert_nil restored.qbo_bill_id
    assert_not restored.accepted?
    assert_equal false, restored.payable?
    assert_equal BigDecimal("20000"), restored.amount
    assert_equal snapshot.id, restored.mso_snapshot_id
  end

  test "a month with nobody on the roster records the benchmark and pays nobody" do
    MsoRolePeriod.where(id: [@chief_role.id, @principal_role.id]).delete_all

    snapshot = run!

    assert_equal [], snapshot.lines
    assert_equal "20000.0", snapshot.benchmark_average
    assert_equal "0.0", snapshot.total_calculated
    assert_equal 0, MsoTrueup.where(invoice_pass_id: @pass.id).count
  end

  # --- refusals -------------------------------------------------------------------

  test "two role periods for one person in the month are refused, naming them" do
    second = MsoRolePeriod.new(contributor: @chief, tier: :svp, title: "Second", started_at: Date.new(2093, 1, 1))
    second.save!(validate: false)

    error = refused

    assert_match(/contributor #{@chief.id}/, error.message)
    assert_match(/#{@chief_role.id}, #{second.id}/, error.message)
    assert_nothing_written
  end

  test "it refuses when Sanctuary has no pass for the month" do
    other = garden3d_pass(Date.new(2093, 7, 1))

    error = refused(pass: other, today: Date.new(2093, 8, 10))

    assert_match(/Sanctuary Computer Inc has no invoice pass for July 2093/, error.message)
  end

  test "it refuses while Sanctuary's pass is not complete" do
    @sanctuary_pass.update_columns(completed_at: nil)

    assert_match(/has not finished invoicing/, refused.message)
    assert_nothing_written
  end

  test "it refuses when Sanctuary's pass has no contributor payouts yet" do
    ContributorPayout.where(invoice_tracker_id: @tracker.id).each(&:destroy)

    assert_match(/no contributor payouts/, refused.message)
    assert_nothing_written
  end

  test "it refuses a month that has not ended" do
    assert_match(/has not ended/, refused(today: Date.new(2093, 5, 31)).message)
    assert_nothing_written
    assert_nothing_raised { run!(today: Date.new(2093, 6, 1)) }
  end

  test "it refuses any pass that is not a runnable garden3d month" do
    assert_match(/garden3d, LLC's pass/, refused(pass: @sanctuary_pass).message)

    start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START
    early = InvoicePass.find_or_create_by!(enterprise: garden3d, start_of_month: start - 1.month) { |p| p.data = {} }
    assert_match(/#{start.strftime('%B %Y')} onward/, refused(pass: early).message)
    assert_equal false, Mso::MonthlyRun.runnable?(early)

    legacy = garden3d_pass(Date.new(2093, 8, 1))
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "Legacy #{SecureRandom.hex(3)}")
    InvoiceTracker.create!(invoice_pass: legacy, forecast_client: client, qbo_account: garden3d_qbo_account,
                           blueprint: { "lines" => { "Line" => { "quantity" => 1, "unit_price" => 1 } } })
    assert_match(/Forecast-driven tracker/, refused(pass: legacy, today: Date.new(2093, 9, 10)).message)
    assert_equal false, Mso::MonthlyRun.runnable?(legacy)

    assert_equal true, Mso::MonthlyRun.runnable?(@pass)
    assert_equal false, Mso::MonthlyRun.runnable?(@sanctuary_pass)
  end

  test "a reconcile variance refuses the run and says how to clear it" do
    charge_fee("100000.0", account_total: "130000.0") # 30,000 in account 4100 that no fee invoice explains

    error = refused

    assert_match(/variance 30000\.0/, error.message)
    assert_match(/attach/i, error.message)
    assert_match(/Managerial Services/, error.message)
    assert_nothing_written
  end

  test "a refused run invalidates the earlier one: nothing stays payable, and only a successful run restores it" do
    first = run!
    trueup_for(@chief).toggle_acceptance!
    trueup_for(@principal).toggle_acceptance!
    assert_equal true, trueup_for(@chief).payable?

    # The month's 4100 row disappears (the fee invoice was voided).
    QboProfitAndLossReport.where(qbo_account_id: garden3d_qbo_account.id, starts_at: MONTH).delete_all
    QboProfitAndLossReport.create!(
      qbo_account: garden3d_qbo_account, starts_at: MONTH, ends_at: MONTH.end_of_month,
      data: { cash: { rows: [] }, accrual: { rows: [["Total Income", "0.0"]] } },
    )

    error = refused

    assert_match(/no account 4100 row/, error.message)
    first.reload
    assert first.current?, "a refused run supersedes nothing"
    assert first.invalidated?
    assert_match(/refused/, first.invalidated_reason)
    assert_not first.fee_collected?
    assert_equal false, trueup_for(@chief).payable?
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount

    # Confirming collection cannot bring it back...
    assert_raises(MsoSnapshot::Unusable) { first.check_collection! }
    assert_equal false, trueup_for(@chief).payable?

    # ...only a run that succeeds can. The amounts did not change, so the
    # acceptances stand.
    charge_fee("100000.0")
    second = run!

    assert_not second.invalidated?
    assert trueup_for(@chief).accepted?
    assert_equal true, trueup_for(@chief).payable?
  end

  test "it asks QuickBooks about collection exactly once, and an uncollected month is not payable" do
    Mso::ManagementFeeInvoices.expects(:collected?).with(invoice_pass: @pass).once.returns(false)

    snapshot = run!

    assert_not snapshot.fee_collected?
    trueup_for(@chief).toggle_acceptance!
    trueup_for(@principal).toggle_acceptance!
    assert_equal false, trueup_for(@chief).payable?
  end

  test "it refuses when a fee invoice cannot be read from QuickBooks" do
    Mso::ManagementFeeInvoices.stubs(:collected?)
      .raises(Mso::ManagementFeeInvoices::RefreshFailed, "Could not read the QuickBooks invoice on InvoiceTracker 1")

    assert_match(/Could not read the QuickBooks invoice/, refused.message)
    assert_nothing_written
  end

  test "it refuses when an executive's garden3d ledger is not QuickBooks-bound" do
    garden3d_ledger(@chief).update!(mode: :legacy)

    error = refused

    assert_match(/Ledger #{garden3d_ledger(@chief).id}/, error.message)
    assert_nothing_written
  end

  test "a failure part-way through writes nothing, and marks the previous run invalid" do
    previous = run!
    pay(@chief, 1_000)
    Mso::MonthlyRun.any_instance.stubs(:apply!).raises(RuntimeError, "boom")

    assert_raises(RuntimeError) { run! }

    previous.reload
    assert previous.current?
    assert previous.invalidated?, "a run that blew up says nothing good about the figures before it"
    assert_equal [previous.id], MsoSnapshot.where(invoice_pass_id: @pass.id).pluck(:id)
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount
  end

  # --- added by the review -----------------------------------------------------------

  test "a founder true-up for someone on the roster refuses the run, naming it" do
    old_style = Trueup.create!(
      invoice_pass: @sanctuary_pass, amount: "4000", description: "founder true-up",
      ledger: Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @principal),
    )

    error = refused

    assert_match(/Trueup #{old_style.id} \(contributor #{@principal.id}/, error.message)
    assert_match(/delete it/, error.message)
    assert_match(/QuickBooks bill/, error.message)
    assert_nothing_written

    old_style.destroy
    assert_nothing_raised { run! }
    assert_equal BigDecimal("23000"), trueup_for(@principal).amount
  end

  test "one month's true-up does not reduce the next month's" do
    run!
    trueup_for(@chief).toggle_acceptance!

    june = Date.new(2093, 6, 1)
    june_sanctuary = sanctuary_pass(june)
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "June Client #{SecureRandom.hex(3)}")
    june_tracker = InvoiceTracker.create!(invoice_pass: june_sanctuary, forecast_client: client,
                                          qbo_account: Enterprise.find(@sanctuary.id).qbo_account)
    { "ja" => 30_000, "jb" => 20_000, "jc" => 10_000 }.each do |tag, amount|
      pay(mso_person("earner-#{tag}"), amount, tracker: june_tracker)
    end
    june_pass = garden3d_pass(june)
    attach_invoice(fee_tracker(june_pass, @payer), qbo_id: "9002", total: "100000.0", balance: "0.0", sent: true)
    fee_report(june, "100000.0")

    snapshot = run!(pass: june_pass, today: Date.new(2093, 7, 10))

    line = line_for(snapshot, @chief)
    assert_equal "0.0", line["already_earned"], "May's true-up is dated 31 May and is May's income"
    assert_equal "20000.0", line["trueup"]
    june_trueup = MsoTrueup.find_by!(invoice_pass_id: june_pass.id, ledger_id: garden3d_ledger(@chief).id)
    assert_equal BigDecimal("20000"), june_trueup.amount
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount
    assert trueup_for(@chief).accepted?, "and running June leaves May alone"
  end

  test "a month can be run long after it ended, and is still dated its own last day" do
    snapshot = run!(today: Date.new(2094, 2, 14))

    chief = trueup_for(@chief)
    assert_equal BigDecimal("20000"), chief.amount
    assert_equal Date.new(2093, 5, 31), chief.payment_date
    assert_equal Date.new(2093, 5, 31), chief.bill_txn_date
    assert_equal MONTH, snapshot.month
  end

  test "an earned figure with a fraction of a cent gives a whole-cent true-up that a re-run does not disturb" do
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @chief)
    # Profit shares are stored unrounded; this is a real one's amount.
    Mso::MonthlyRun.stubs(:already_earned).returns({})
    Mso::MonthlyRun.stubs(:already_earned).with(has_entry(contributor_id: @chief.id))
      .returns({ sanctuary_ledger.id => BigDecimal("179.8089646737429") })

    snapshot = run!

    chief = trueup_for(@chief)
    line = line_for(snapshot, @chief)
    assert_equal BigDecimal("19820.19"), chief.amount, "20000 - 179.8089646737429, rounded DOWN"
    assert_equal "19820.19", line["trueup"]
    assert_equal "19820.1910353262571", line["trueup_before_rounding"]
    assert_equal BigDecimal("42820.19"), snapshot.total_trueup

    chief.toggle_acceptance!(expected_amount: "19820.19")
    second = run!

    again = trueup_for(@chief)
    assert_equal chief.id, again.id
    assert again.accepted?, "the same whole-cent amount must not clear the acceptance"
    assert_equal BigDecimal("19820.19"), again.amount
    assert_equal [], second.drift
  end

  test "a true-up of less than a cent creates no row and expects no acceptance" do
    sanctuary_ledger = Ledger.find_or_create_for(enterprise: @sanctuary, contributor: @chief)
    Mso::MonthlyRun.stubs(:already_earned).returns({})
    Mso::MonthlyRun.stubs(:already_earned).with(has_entry(contributor_id: @chief.id))
      .returns({ sanctuary_ledger.id => BigDecimal("19999.996") })

    snapshot = run!

    assert_nil trueup_for(@chief)
    line = line_for(snapshot, @chief)
    assert_equal "0.0", line["trueup"]
    assert_equal "0.004", line["trueup_before_rounding"]
    assert_equal [garden3d_ledger(@principal).id], snapshot.expected_ledger_ids
    assert_equal BigDecimal("23000"), snapshot.total_trueup
  end

  test "preview computes the same amounts, writes nothing and asks QuickBooks nothing" do
    Mso::ManagementFeeInvoices.stubs(:collected?).raises(RuntimeError, "preview asked QuickBooks")

    amounts = Mso::MonthlyRun.preview(invoice_pass: @pass, today: TODAY)

    assert_equal(
      { garden3d_ledger(@chief).id => BigDecimal("20000"), garden3d_ledger(@principal).id => BigDecimal("23000") },
      amounts,
    )
    assert_nothing_written

    # It refuses where a run would, and a refused preview invalidates nothing.
    Mso::ManagementFeeInvoices.stubs(:collected?).returns(true)
    first = run!
    charge_fee("100000.0", account_total: "130000.0")
    assert_raises(Mso::MonthlyRun::Refused) { Mso::MonthlyRun.preview(invoice_pass: @pass, today: TODAY) }
    assert_not first.reload.invalidated?
  end

  test "a run takes the pass's row lock, and a second run replaces the first instead of standing beside it" do
    InvoicePass.any_instance.expects(:lock!).at_least(2)

    run!
    second = run!

    assert_equal [second.id], MsoSnapshot.current.where(invoice_pass_id: @pass.id).pluck(:id)
    assert_equal 2, MsoSnapshot.where(invoice_pass_id: @pass.id).count
    assert_equal 2, MsoTrueup.where(invoice_pass_id: @pass.id).count
    # The backstop if two runs ever got past the lock: the database refuses a
    # second current snapshot for the pass.
    assert_raises(ActiveRecord::RecordNotUnique) { mso_snapshot(@pass) }
  end

  test "a billed true-up plus recomputed ones can exceed a cap that has fallen; the snapshot says so" do
    run!
    trueup_for(@chief).update_columns(accepted_at: Time.current, qbo_bill_id: "88")
    charge_fee("40000.0") # the cap is now 22,000

    snapshot = run!

    assert_equal BigDecimal("22000"), snapshot.cap
    assert_equal BigDecimal("22000"), snapshot.total_trueup, "what this run computed: 10,232.56 + 11,767.44"
    assert_equal BigDecimal("31767.44"), snapshot.total_trueup_as_billed, "the billed 20,000 stands: + 11,767.44"
    assert snapshot.over_cap?
    assert_equal BigDecimal("20000"), trueup_for(@chief).amount
    assert_equal BigDecimal("11767.44"), trueup_for(@principal).amount
  end
end
