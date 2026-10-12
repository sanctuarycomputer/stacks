# Builders for MSO true-up, snapshot and monthly-run tests. Builds on
# ManagementFeeFixtures (garden3d's QuickBooks account, pass and fee trackers).
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

  # One snapshot line, shaped as Mso::MonthlyRun writes it.
  def mso_line(role, ledger, trueup:, already_earned: "0.0")
    {
      "mso_role_period_id" => role.id, "contributor_id" => role.contributor_id, "ledger_id" => ledger.id,
      "tier" => role.tier, "title" => role.title, "multiplier" => role.tier_multiplier.to_s("F"),
      "started_at" => role.started_at.iso8601, "ended_at" => role.ended_at&.iso8601,
      "already_earned" => already_earned, "earned_by_ledger" => {},
      "calculated" => trueup, "final" => trueup, "reduction" => "0.0", "trueup" => trueup,
      "trueup_before_rounding" => trueup
    }
  end

  def mso_snapshot(pass, lines: [], collected: false)
    sanctuary = InvoicePass.find_by(enterprise: enterprises(:sanctuary), start_of_month: pass.start_of_month) ||
                sanctuary_pass(pass.start_of_month)
    MsoSnapshot.create!(
      invoice_pass: pass, sanctuary_invoice_pass: sanctuary, fee_income: "100000", benchmark_average: "20000.0",
      configured_n: 3, counted: 3, small_sample: false, cap_percentage: "0.55", cap: "55000",
      total_calculated: "20000.0",
      total_trueup: lines.sum(BigDecimal("0")) { |line| BigDecimal(line["trueup"]) },
      total_trueup_as_billed: lines.sum(BigDecimal("0")) { |line| BigDecimal(line["trueup"]) },
      lines: lines, fee_collected_at: collected ? Time.current : nil,
    )
  end

  def mso_trueup(snapshot, role, ledger, amount:, accepted: false)
    MsoTrueup.create!(ledger: ledger, invoice_pass: snapshot.invoice_pass, mso_snapshot: snapshot,
                      mso_role_period: role, amount: amount, description: "MSO true-up",
                      accepted_at: accepted ? Time.current : nil)
  end

  # A stored accrual P&L for garden3d with `amount` on account 4100.
  def fee_report(month, amount)
    QboProfitAndLossReport.create!(
      qbo_account: garden3d_qbo_account, starts_at: month, ends_at: month.end_of_month,
      data: { cash: { rows: [] }, accrual: { rows: [["4100 Management Fee Income", amount], ["Total Income", amount]] } },
    )
  end
end
