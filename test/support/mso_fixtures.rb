# Builders for MSO true-up tests. Builds on ManagementFeeFixtures (garden3d's
# QuickBooks account, pass and fee trackers).
module MsoFixtures
  include ManagementFeeFixtures

  def mso_admin
    @mso_admin ||= AdminUser.create!(email: "mso-admin-#{SecureRandom.hex(3)}@example.com",
                                     password: "password12345", roles: ["admin"])
  end

  # A contributor. ForecastPerson's after_create may already have made one.
  # `login:` gives them an AdminUser, matched to the ForecastPerson by email.
  def mso_person(tag, login: true)
    email = "mso-#{tag}-#{SecureRandom.hex(3)}@example.com"
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    AdminUser.create!(email: email, password: "password12345") if login
    fp.contributor || Contributor.create!(forecast_person: fp)
  end

  def login_for(contributor)
    AdminUser.find_by!(email: contributor.forecast_person.email)
  end

  def garden3d_ledger(contributor)
    Ledger.find_or_create_for(enterprise: garden3d, contributor: contributor)
  end

  def sanctuary_pass(month, completed: true)
    InvoicePass.create!(start_of_month: month, enterprise: enterprises(:sanctuary), data: {},
                        completed_at: completed ? Time.current : nil)
  end

  def mso_role(contributor, tier: :chief, title: "Operations", started_at: Date.new(2090, 1, 1), ended_at: nil)
    MsoRolePeriod.create!(contributor: contributor, tier: tier, title: title,
                          started_at: started_at, ended_at: ended_at)
  end

  # The month's report, as the nightly step makes it.
  def mso_report(month)
    PeriodicReport.month.find_or_create_by!(period_starts_at: month) do |report|
      report.period_label = month.strftime("%B %Y")
    end
  end

  # A true-up shaped as PeriodicReport#sync_mso_trueups! writes one.
  def mso_trueup(report, role, ledger, amount:, accepted: false)
    figure = BigDecimal(amount.to_s).to_s("F")
    MsoTrueup.create!(
      periodic_report: report, ledger: ledger, amount: amount, description: "MSO true-up",
      accepted_at: accepted ? Time.current : nil,
      blueprint: {
        "mso_role_period_id" => role.id, "contributor_id" => role.contributor_id, "tier" => role.tier,
        "title" => role.title, "multiplier" => role.tier_multiplier.to_s("F"), "already_earned" => "0.0",
        "earned_by_ledger" => {}, "calculated" => figure, "final" => figure, "reduction" => "0.0",
        "trueup" => figure
      },
    )
  end

  # garden3d's pass for the month, answering `collected` to
  # management_fee_collected? (the rule itself has its own tests).
  def fee_collected(month, collected = true)
    pass = InvoicePass.find_by(enterprise: garden3d, start_of_month: month) || garden3d_pass(month)
    InvoicePass.any_instance.stubs(:management_fee_collected?).returns(collected)
    pass
  end

  # --- a whole month that can be computed --------------------------------------

  # Sanctuary's completed pass with a top three of 30,000 / 20,000 / 10,000
  # (benchmark 20,000); garden3d's pass with one payer whose 100,000 fee is
  # invoiced, paid and on account 4100 (cap 55,000); and two executives:
  # @chief (1.00x, 20,000) and @principal (1.15x, 23,000). Nothing built here
  # may reach QuickBooks.
  def build_mso_month(month)
    @mso_month = month
    @sanctuary = enterprises(:sanctuary)
    @sanctuary_pass = sanctuary_pass(month)
    client = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: "Run Client #{SecureRandom.hex(3)}")
    @tracker = InvoiceTracker.create!(invoice_pass: @sanctuary_pass, forecast_client: client,
                                      qbo_account: Enterprise.find(@sanctuary.id).qbo_account)

    garden3d_qbo_account
    @pass = garden3d_pass(month)
    @payer = make_payer("Run Payer #{SecureRandom.hex(3)}", customer_id: "2")
    @fee_tracker = fee_tracker(@pass, @payer)
    charge_fee("100000.0")

    @top = earner("a", 30_000)
    earner("b", 20_000)
    earner("c", 10_000)

    @chief = mso_person("chief")
    @chief_role = mso_role(@chief, tier: :chief, title: "Operations")
    @principal = mso_person("principal")
    @principal_role = mso_role(@principal, tier: :principal, title: "Founder")

    QboProfitAndLossReport.stubs(:find_or_fetch_for_range).raises(RuntimeError, "unexpected QuickBooks read")
    QboInvoice.any_instance.stubs(:sync!).raises(RuntimeError, "unexpected QuickBooks read")
    QboAccount.any_instance.stubs(:make_and_refresh_qbo_access_token)
      .raises(RuntimeError, "unexpected QuickBooks call")
  end

  # garden3d's fee for the month: one paid invoice and a 4100 row.
  def charge_fee(amount, account_total: amount)
    QboInvoice.where(qbo_account_id: garden3d_qbo_account.id, qbo_id: "9001").delete_all
    QboProfitAndLossReport.where(qbo_account_id: garden3d_qbo_account.id, starts_at: @mso_month).delete_all
    # A fresh copy of the tracker: where the database carries the composite
    # foreign key to qbo_invoices, deleting the mirror above nulls the
    # tracker's qbo_invoice_id, and a stale copy would not re-attach it.
    attach_invoice(InvoiceTracker.find(@fee_tracker.id), qbo_id: "9001", total: amount, balance: "0.0", sent: true)
    fee_report(@mso_month, account_total)
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

  # A stored accrual P&L for garden3d with `amount` on account 4100.
  def fee_report(month, amount)
    QboProfitAndLossReport.create!(
      qbo_account: garden3d_qbo_account, starts_at: month, ends_at: month.end_of_month,
      data: { cash: { rows: [] }, accrual: { rows: [["4100 Management Fee Income", amount], ["Total Income", amount]] } },
    )
  end
end
