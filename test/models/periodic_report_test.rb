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
    pass = InvoicePass.find_or_create_by!(start_of_month: month_start, enterprise: Enterprise.sanctuary) { |ip| ip.data = {} }
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
    # A cost-of-living override, so no DeelPerson is needed.
    eligible = make_contributor!("conan@sanctuary.computer")
    eligible.update!(cost_of_living_country: "United States")
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

  def link_deel_person!(contributor, country_code)
    deel = DeelPerson.create!(deel_id: SecureRandom.uuid, data: { "addresses" => [{ "country" => country_code }] })
    contributor.update!(deel_person_id: deel.deel_id)
    deel
  end

  def work_full_quarter!(contributor)
    project = make_project_billed_through!(@sanctuary, "Client #{rand(10_000)}")
    [4, 5, 6].each do |month|
      assign_hours!(contributor, project, Date.new(2026, month, 1), Date.new(2026, month, 28))
    end
  end

  test "cost of living comes from the Deel address when there is no override" do
    contributor = make_contributor!("estonia@sanctuary.computer")
    link_deel_person!(contributor, "EE")

    assert_equal "Estonia", @report.cost_of_living_data_for(contributor)[:country]
  end

  test "the cost-of-living override takes precedence over the Deel address" do
    contributor = make_contributor!("moved@sanctuary.computer")
    link_deel_person!(contributor, "EE")
    contributor.update!(cost_of_living_country: "Portugal")

    assert_equal "Portugal", @report.cost_of_living_data_for(contributor)[:country]
  end

  test "the override works for a contributor with no Deel person" do
    contributor = make_contributor!("nodeel@sanctuary.computer")
    contributor.update!(cost_of_living_country: "Canada")
    work_full_quarter!(contributor)

    data = @report.tentative_profit_shares_by_contributor.values.find { |d| d[:email] == "nodeel@sanctuary.computer" }
    assert_equal "Canada", data[:cost_of_living_data][:country]
  end

  test "every eligible contributor without a cost-of-living country is named in one error" do
    first = make_contributor!("first@sanctuary.computer")
    second = make_contributor!("second@sanctuary.computer")
    fine = make_contributor!("fine@sanctuary.computer")
    fine.update!(cost_of_living_country: "United States")
    [first, second, fine].each { |c| work_full_quarter!(c) }

    error = assert_raises(Stacks::Errors::Base) { @report.tentative_profit_shares_by_contributor }
    assert_includes error.message, "first@sanctuary.computer"
    assert_includes error.message, "second@sanctuary.computer"
    refute_includes error.message, "fine@sanctuary.computer"
  end
end
