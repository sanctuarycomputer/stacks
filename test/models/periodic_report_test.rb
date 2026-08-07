require 'test_helper'

class PeriodicReportTest < ActiveSupport::TestCase
  setup do
    Thread.current[:sanctuary_enterprise] = nil
    Thread.current[:garden3d_enterprise] = nil
    @sanctuary = enterprises(:sanctuary)
    @garden3d = Enterprise.create!(name: Enterprise::GARDEN3D_NAME)
    @other = enterprises(:one)
    @report = PeriodicReport.create!(
      period_gradation: :quarter,
      period_starts_at: Date.new(2026, 4, 1),
      period_label: "Q2, 2026"
    )
  end

  def make_contributor!(email)
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    fp.contributor
  end

  def make_project_billed_through!(enterprise, name)
    fc = ForecastClient.create!(forecast_id: rand(1..2_000_000_000), name: name)
    EnterpriseForecastClient.create!(enterprise: enterprise, forecast_client: fc)
    ForecastProject.create!(
      forecast_id: rand(1..2_000_000_000),
      name: "#{name} Project",
      forecast_client: fc,
      code: "#{name}-#{rand(10_000)}"
    )
  end

  def assign_hours!(contributor, project, start_date, end_date, seconds_per_day = 8 * 60 * 60)
    ForecastAssignment.create!(
      forecast_id: rand(1..2_000_000_000),
      forecast_person: contributor.forecast_person,
      forecast_project: project,
      start_date: start_date,
      end_date: end_date,
      allocation: seconds_per_day
    )
  end

  def pay_trueup!(contributor, enterprise, month_start, amount)
    pass = InvoicePass.find_or_create_by!(start_of_month: month_start) { |ip| ip.data = {} }
    ledger = Ledger.find_or_create_for(enterprise: enterprise, contributor: contributor)
    Trueup.create!(ledger: ledger, invoice_pass: pass, amount: amount, description: "test trueup")
  end

  def quarter_by_month(contributor)
    contributor.all_items_grouped_by_month(
      false, @report.period.starts_at, @report.period.ends_at + 1.day
    )[:by_month]
  end

  test "eligible_profit_share_email? accepts only sanctuary.computer and xxix.co domains" do
    assert PeriodicReport.eligible_profit_share_email?("kay@sanctuary.computer")
    assert PeriodicReport.eligible_profit_share_email?("sam@xxix.co")
    assert PeriodicReport.eligible_profit_share_email?("SAM@XXIX.CO")
    refute PeriodicReport.eligible_profit_share_email?("info@driesbos.com")
    refute PeriodicReport.eligible_profit_share_email?("kay@sanctuary.computer.evil.com")
    refute PeriodicReport.eligible_profit_share_email?(nil)
    refute PeriodicReport.eligible_profit_share_email?("")
  end

  test "elevated service counts hours only on clients billed through Sanctuary or garden3d" do
    contributor = make_contributor!("worker@sanctuary.computer")
    sanctuary_project = make_project_billed_through!(@sanctuary, "Sanctuary Client")
    garden3d_project = make_project_billed_through!(@garden3d, "Garden3d Client")
    other_project = make_project_billed_through!(@other, "Other Enterprise Client")

    # ~240 recorded hours in each month — far past the 120hr elevated-service bar,
    # but April's hours bill through an out-of-scope enterprise.
    assign_hours!(contributor, other_project, Date.new(2026, 4, 1), Date.new(2026, 4, 30))
    assign_hours!(contributor, sanctuary_project, Date.new(2026, 5, 1), Date.new(2026, 5, 31))
    assign_hours!(contributor, garden3d_project, Date.new(2026, 6, 1), Date.new(2026, 6, 30))

    flags = @report.profit_share_elevated_service_by_month(contributor, quarter_by_month(contributor))
    by_label = flags.transform_keys(&:label)

    refute by_label["April, 2026"], "hours billed through an out-of-scope enterprise must not count"
    assert by_label["May, 2026"], "Sanctuary-billed hours count"
    assert by_label["June, 2026"], "garden3d-billed hours count"
  end

  test "elevated service counts income only on Sanctuary or garden3d ledgers" do
    contributor = make_contributor!("worker@sanctuary.computer")

    pay_trueup!(contributor, @other, Date.new(2026, 4, 1), 20_000)
    pay_trueup!(contributor, @sanctuary, Date.new(2026, 5, 1), 9_500)
    pay_trueup!(contributor, @garden3d, Date.new(2026, 6, 1), 9_500)

    flags = @report.profit_share_elevated_service_by_month(contributor, quarter_by_month(contributor))
    by_label = flags.transform_keys(&:label)

    refute by_label["April, 2026"], "income on an out-of-scope enterprise ledger must not count"
    assert by_label["May, 2026"], "Sanctuary ledger income counts"
    assert by_label["June, 2026"], "garden3d ledger income counts"
  end

  test "tentative profit shares exclude non-company emails and out-of-scope work" do
    # conan@ is on the US cost-of-living override list, so no DeelPerson is needed.
    eligible = make_contributor!("conan@sanctuary.computer")
    wrong_email = make_contributor!("freelance@gmail.com")
    wrong_enterprise = make_contributor!("elsewhere@sanctuary.computer")

    sanctuary_project = make_project_billed_through!(@sanctuary, "Client A")
    other_project = make_project_billed_through!(@other, "Client B")

    [4, 5, 6].each do |month|
      assign_hours!(eligible, sanctuary_project, Date.new(2026, month, 1), Date.new(2026, month, 28))
      assign_hours!(wrong_email, sanctuary_project, Date.new(2026, month, 1), Date.new(2026, month, 28))
      assign_hours!(wrong_enterprise, other_project, Date.new(2026, month, 1), Date.new(2026, month, 28))
    end

    result = @report.tentative_profit_shares_by_contributor
    emails = result.values.map { |data| data[:email] }

    assert_includes emails, "conan@sanctuary.computer"
    refute_includes emails, "freelance@gmail.com", "company-email rule must exclude external addresses"
    refute_includes emails, "elsewhere@sanctuary.computer", "enterprise-scope rule must exclude out-of-scope work"

    eligible_data = result.values.find { |data| data[:email] == "conan@sanctuary.computer" }
    assert_equal 3, eligible_data[:elevated_service_months]
  end
end
