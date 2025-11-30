class ProfitSharePass < ApplicationRecord
  has_many :profit_share_payments, dependent: :destroy

  def self.this_year
    ProfitSharePass.all.select{|p| p.created_at.year == Time.now.year}.first
  end

  def loosen_considered_successful_requirement_for_project_leadership_psu?
    return false
  end

  scope :finalized , -> {
    ProfitSharePass.where.not(snapshot: nil)
  }

  def display_name
    "#{created_at.year} Profit Share"
  end

  def finalized?
    snapshot.present?
  end

  def finalized_at
    snapshot && DateTime.parse(snapshot["finalized_at"])
  end

  def unfinalize!
    ActiveRecord::Base.transaction do
      profit_share_payments.destroy_all
      update!(snapshot: nil)
    end
  end

  def finalize!(scenario = make_scenario, force = false)
    if finalized? && !force
      raise "Profit share pass already finalized"
    end

    ActiveRecord::Base.transaction do
      profit_share_payments.destroy_all

      update!(snapshot: {
        finalized_at: DateTime.now,
        inputs: {
          actuals: scenario.actuals,
          total_psu_issued: scenario.total_psu_issued,
          pre_spent: scenario.pre_spent,
          desired_buffer_months: scenario.desired_buffer_months,
          efficiency_cap: scenario.efficiency_cap,
          internals_budget_multiplier: scenario.internals_budget_multiplier,
          projected_monthly_cost_of_doing_business: scenario.projected_monthly_cost_of_doing_business,
          fica_tax_rate: scenario.fica_tax_rate,
          pre_spent_reinvestment: scenario.pre_spent_reinvestment
        }
      })

      payments(scenario).each do |payment|
        profit_share_payments.create!({
          admin_user: payment[:admin_user],
          tenured_psu_earnt: payment[:tenured_psu_earnt],
          project_leadership_psu_earnt: payment[:project_leadership_psu_earnt],
          collective_leadership_psu_earnt: payment[:collective_leadership_psu_earnt],
          pre_spent_profit_share: payment[:pre_spent_profit_share],
          total_payout: payment[:total_payout]
        })
      end
    end
  end

  def self.ensure_exists!
    # TODO: Uncomment this when dashboard fixed
    # return nil if Time.now.year >= 2025
    ProfitSharePass.this_year || ProfitSharePass.create!
  end

  def is_projection?
    !finalized?
  end

  def prespent_profit_share
    (PreProfitSharePurchase.where(
      purchased_at: Date.new(created_at.year).beginning_of_year..Date.new(created_at.year).end_of_year
    ).map(&:amount).reduce(:+) || 0.0)
  end

  def net_revenue_by_reinvestment_studio(accounting_method = "cash")
    @_net_revenue_by_reinvestment_studio ||= (
      Studio.reinvestment.reduce({}) do |acc, studio|
        acc[studio] = {
          net_revenue: studio.net_revenue(accounting_method, created_at)
        }
        acc
      end
    )
  end

  def total_reinvestment_spend(accounting_method = "cash")
    net_revenue_by_reinvestment_studio(accounting_method).reduce(0) do |acc, tuple|
      studio, data = tuple
      acc += data[:net_revenue].abs if data[:net_revenue].present? && data[:net_revenue] < 0
      acc
    end
  end

  def finalization_day
    Date.new(created_at.year, 12, 15)
  end

  def leadership_psu_pool
    g3d = Studio.garden3d
    xxix = Studio.find_by(mini_name: "xxix")
    sanctu = Studio.find_by(mini_name: "sanctu")

    g3d_ytd_revenue_growth_okr = g3d.ytd_snapshot.dig("accrual", "okrs_excluding_reinvestment", "Revenue Growth")
    g3d_ytd_revenue_growth_progress = Okr.make_annual_growth_progress_data(
      g3d_ytd_revenue_growth_okr["target"].to_f.round(2),
      g3d_ytd_revenue_growth_okr["tolerance"].to_f.round(2),
      g3d.last_year_snapshot.dig("accrual", "datapoints_excluding_reinvestment", "revenue", "value"),
      g3d.ytd_snapshot.dig("accrual", "datapoints_excluding_reinvestment", "revenue", "value"),
      :usd
    )

    g3d_ytd_lead_growth_okr = g3d.ytd_snapshot.dig("accrual", "okrs_excluding_reinvestment", "Lead Growth")
    g3d_ytd_lead_growth_progress = Okr.make_annual_growth_progress_data(
      g3d_ytd_lead_growth_okr["target"].to_f.round(2),
      g3d_ytd_lead_growth_okr["tolerance"].to_f.round(2),
      g3d.last_year_snapshot.dig("accrual", "datapoints_excluding_reinvestment", "lead_count", "value"),
      g3d.ytd_snapshot.dig("accrual", "datapoints_excluding_reinvestment", "lead_count", "value"),
      :count
    )

    collective_okrs = [{
      "datapoint" => "profit_margin",
      "okr" => g3d.ytd_snapshot.dig("accrual", "okrs_excluding_reinvestment", "Profit Margin"),
      "role_holders" => [*CollectiveRole.find_by(name: "General Manager").try(:current_collective_role_holders)]
    }, {
      "datapoint" => "revenue_growth",
      "okr" => g3d_ytd_revenue_growth_okr,
      "growth_progress" => g3d_ytd_revenue_growth_progress,
      "role_holders" => [*CollectiveRole.find_by(name: "General Manager").try(:current_collective_role_holders)]
    }, {
      "datapoint" => "successful_design_projects",
      "okr" => xxix.ytd_snapshot.dig("accrual", "okrs", "Successful Projects"),
      "role_holders" => [
        *CollectiveRole.find_by(name: "Creative Director").try(:current_collective_role_holders),
        *CollectiveRole.find_by(name: "Apprentice Creative Director").try(:current_collective_role_holders),
        *CollectiveRole.find_by(name: "Director of Project Delivery").try(:current_collective_role_holders),
      ]
    }, {
      "datapoint" => "successful_development_projects",
      "okr" => sanctu.ytd_snapshot.dig("accrual", "okrs", "Successful Projects"),
      "role_holders" => [
        *CollectiveRole.find_by(name: "Technical Director").try(:current_collective_role_holders),
        *CollectiveRole.find_by(name: "Apprentice Technical Director").try(:current_collective_role_holders),
        *CollectiveRole.find_by(name: "Director of Project Delivery").try(:current_collective_role_holders),
      ]
    }, {
      "datapoint" => "successful_design_proposals",
      "okr" => xxix.ytd_snapshot.dig("accrual", "okrs", "Successful Proposals"),
      "role_holders" => [
        *CollectiveRole.find_by(name: "Director of Business Development").try(:current_collective_role_holders),
        *CollectiveRole.find_by(name: "Creative Director").try(:current_collective_role_holders),
      ]
    }, {
      "datapoint" => "successful_development_proposals",
      "okr" => sanctu.ytd_snapshot.dig("accrual", "okrs", "Successful Proposals"),
      "role_holders" => [
        *CollectiveRole.find_by(name: "Director of Business Development").try(:current_collective_role_holders),
        *CollectiveRole.find_by(name: "Technical Director").try(:current_collective_role_holders)
      ]
    }, {
      "datapoint" => "lead_growth",
      "okr" => g3d_ytd_lead_growth_okr,
      "growth_progress" => g3d_ytd_lead_growth_progress,
      "role_holders" => [
        *CollectiveRole.find_by(name: "Director of Business Development").try(:current_collective_role_holders),
        *CollectiveRole.find_by(name: "Director of Communications").try(:current_collective_role_holders)
      ]
    }, {
      "datapoint" => "workplace_satisfaction",
      "okr" => g3d.ytd_snapshot.dig("accrual", "okrs_excluding_reinvestment", "Workplace Satisfaction"),
      "role_holders" => [
        *CollectiveRole.find_by(name: "Director of Project Delivery").try(:current_collective_role_holders),
        *CollectiveRole.find_by(name: "Director of People Ops").try(:current_collective_role_holders)
      ]
    }]

    collective_okrs.each do |dp|
      if dp["okr"].nil?
        dp["awarded_psu"] = 0
        next
      end

      dp["awarded_psu"] = Stacks::Utils.clamp(
        dp.dig("okr", "value") || 0,
        dp.dig("okr", "target").to_f - dp.dig("okr", "tolerance").to_f,
        dp.dig("okr", "target").to_f + dp.dig("okr", "tolerance").to_f,
        0,
        (leadership_psu_pool_cap.to_f / collective_okrs.count)*2
      )
    end

    {
      "collective_okrs" => collective_okrs,
      "total_claimable" => collective_okrs.map{|dp| dp["awarded_psu"] }.reduce(&:+).clamp(0, leadership_psu_pool_cap),
      "max" => leadership_psu_pool_cap
    }.deep_stringify_keys
  end

  def days_this_year
    created_at.end_of_year.yday
  end

  def make_period
    Stacks::Period.new(
      "#{created_at.beginning_of_quarter.year}",
      created_at.beginning_of_year,
      created_at.end_of_year
    )
  end

  def collective_leadership_days_by_admin_user
    period = make_period

    @_collective_leadership_days_by_admin_user ||= Studio.garden3d.core_members_active_on(finalization_day).includes(
      :collective_role_holder_periods
    ).reduce({}) do |acc, a|
      acc[a] = a.collective_roles_in_period(period).reduce({}) do |axx, r|
        axx[r] = {
          days: r.effective_days_in_role_during_range(period.starts_at, period.ends_at),
          weight: r.collective_role.leadership_psu_pool_weighting
        }
        axx
      end
      acc
    end
  end

  def awarded_collective_leadership_psu_proportion_for_admin_user(admin_user)
    collective_role_days = collective_leadership_days_by_admin_user[admin_user] || {}

    # Calculate this admin user's weighted days
    individual_weighted_days = collective_role_days.values.reduce(0) do |acc, data|
      acc + (data[:days] * data[:weight])
    end

    total_possible_days = max_possible_collective_leadership_weighted_days_for_year
    return 0 if total_possible_days == 0

    # Calculate proportion based on maximum possible days
    individual_weighted_days / total_possible_days.to_f
  end

  def max_possible_collective_leadership_weighted_days_for_year
    @_max_possible_collective_leadership_weighted_days_for_year ||= CollectiveRole.where(
      "created_at <= ?", finalization_day
    ).reduce(0) do |acc, role|
      acc + (days_this_year * role.leadership_psu_pool_weighting)
    end
  end

  def project_leadership_days_by_admin_user
    period = make_period
    @_project_leadership_days_by_admin_user ||= Studio.garden3d.core_members_active_on(finalization_day).includes(
      full_time_periods: [],
      technical_lead_periods: [project_tracker: [:forecast_assignments, :project_capsule]],
      creative_lead_periods: [project_tracker: [:forecast_assignments, :project_capsule]],
      project_lead_periods: [project_tracker: [:forecast_assignments, :project_capsule]]
    ).reduce({}) do |acc, a|
      acc[a] = a.project_roles_in_period(period).reduce({}) do |axx, r|
        axx[r] = {
          days: r.effective_days_in_role_during_range(period.starts_at, period.ends_at),
          considered_successful: r.project_tracker.considered_successful?
        }
        axx
      end
      acc
    end
  end

  def includes_leadership_psu_pool?
    leadership_psu_pool_cap > 0
  end

  def total_effective_successful_project_leadership_days
    @_total_effective_successful_project_leadership_days ||= project_leadership_days_by_admin_user.reduce(0) do |acc, tuple|
      admin_user, data = tuple
      acc += data.values.map do |d|
        d[:considered_successful] ? d[:days] : 0
      end.reduce(&:+) || 0
      acc
    end
  end

  def total_effective_project_leadership_days
    @_total_effective_project_leadership_days ||= project_leadership_days_by_admin_user.reduce(0) do |acc, tuple|
      admin_user, data = tuple
      acc += data.values.map{|d| d[:days]}.reduce(&:+) || 0
      acc
    end
  end

  def awarded_project_leadership_psu_proportion_for_admin_user(admin_user)
    return 0 if total_effective_successful_project_leadership_days == 0
    project_role_days = project_leadership_days_by_admin_user[admin_user] || {}

    project_leadership_days = (project_role_days.reduce(0) do |acc, tuple|
      role, d = tuple
      if loosen_considered_successful_requirement_for_project_leadership_psu?
        acc += d[:days]
      else
        acc += d[:considered_successful] ? d[:days] : 0
      end
      acc
    end || 0)

    if loosen_considered_successful_requirement_for_project_leadership_psu?
      project_leadership_days / total_effective_project_leadership_days.to_f
    else
      project_leadership_days / total_effective_successful_project_leadership_days.to_f
    end
  end

  def psu_distributions
    @_psu_distributions ||= begin
      lpp = leadership_psu_pool

      Studio.garden3d.core_members_active_on(finalization_day).map do |a|
        tenured_psu_earnt = a.psu_earned_by(finalization_day) || 0

        collective_leadership_psu_earnt = (
          awarded_collective_leadership_psu_proportion_for_admin_user(a) *
          lpp["total_claimable"] *
          ((100 - leadership_psu_pool_project_role_holders_percentage) / 100)
        ) || 0

        project_leadership_psu_earnt = (
          awarded_project_leadership_psu_proportion_for_admin_user(a) *
          lpp["total_claimable"] *
          (leadership_psu_pool_project_role_holders_percentage / 100)
        ) || 0

        {
          admin_user: a,
          tenured: tenured_psu_earnt,
          project_leadership: project_leadership_psu_earnt,
          collective_leadership: collective_leadership_psu_earnt,
          total: tenured_psu_earnt + project_leadership_psu_earnt + collective_leadership_psu_earnt
        }
      end
    end
  end

  def payments(scenario = make_scenario)
    if profit_share_payments.any?
      return profit_share_payments.map do |payment|
        {
          admin_user: payment.admin_user,
          psu_value: scenario.actual_value_per_psu,
          tenured_psu_earnt: payment.tenured_psu_earnt,
          project_leadership_psu_earnt: payment.project_leadership_psu_earnt,
          collective_leadership_psu_earnt: payment.collective_leadership_psu_earnt,
          pre_spent_profit_share: payment.pre_spent_profit_share,
          total_payout: payment.total_payout
        }
      end
    end

    psu_value = scenario.actual_value_per_psu
    psu_distributions.map do |psud|
      pre_spent_profit_share = psud[:admin_user].pre_profit_share_spent_during(finalization_day.year)
      {
        admin_user: psud[:admin_user],
        psu_value: psu_value,
        tenured_psu_earnt: psud[:tenured],
        project_leadership_psu_earnt: psud[:project_leadership],
        collective_leadership_psu_earnt: psud[:collective_leadership],
        pre_spent_profit_share: pre_spent_profit_share,
        total_payout: (psu_value * psud[:total]) - pre_spent_profit_share
      }
    end
  end

  def total_psu_issued
    if finalized?
      snapshot["inputs"]["total_psu_issued"].to_f
    else
      psu_distributions.map{|d| d[:total]}.reduce(&:+) || 0
    end
  end

  def projected_monthly_cost_of_doing_business
    Studio.garden3d.snapshot["trailing_6_months"].last.dig("cash", "datapoints_excluding_reinvestment", "cogs", "value") / 6
  end

  def pull_outstanding_invoices
    access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

    invoice_service = Quickbooks::Service::Invoice.new
    invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
    invoice_service.access_token = access_token
    invoice_service.query("Select * From Invoice Where Balance > '0.0'")
  end

  def pull_actuals_for_year
    year = created_at.year
    qbo_access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token
    report_service = Quickbooks::Service::Reports.new
    report_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
    report_service.access_token = qbo_access_token

    time = DateTime.parse("1st Jan #{year}")
    report = report_service.query("ProfitAndLoss", nil, {
      start_date: time.strftime("%Y-%m-%d"),
      end_date: time.end_of_year.strftime("%Y-%m-%d"),
      accounting_method: "Cash"
    })

    {
      gross_revenue: (report.find_row("Total Income").try(:[], 1) || 0),
      gross_payroll: (report.find_row("Total [SC] Payroll").try(:[], 1) || 0),
      gross_benefits: (report.find_row("Total [SC] Benefits, Contributions & Tax").try(:[], 1) || 0),
      gross_subcontractors: (report.find_row("Total [SC] Subcontractors").try(:[], 1) || 0),
      gross_expenses: (
        (report.find_row("Total Expenses").try(:[], 1) || 0) +
        (report.find_row("Total [SC] Supplies & Materials").try(:[], 1) || 0)
      )
    }
  end

  def make_scenario(
    gross_revenue_override = nil,
    gross_payroll_override = nil,
    gross_benefits_override = nil,
    gross_expenses_override = nil,
    gross_subcontractors_override = nil
  )
    if finalized?
      Stacks::ProfitShare::Scenario.new(
        snapshot["inputs"]["actuals"].symbolize_keys,
        snapshot["inputs"]["total_psu_issued"].to_f,
        snapshot["inputs"]["pre_spent"].to_f,
        snapshot["inputs"]["desired_buffer_months"].to_f,
        snapshot["inputs"]["efficiency_cap"].to_f,
        snapshot["inputs"]["internals_budget_multiplier"].to_f,
        snapshot["inputs"]["projected_monthly_cost_of_doing_business"].to_f,
        snapshot["inputs"]["fica_tax_rate"].to_f,
        snapshot["inputs"]["pre_spent_reinvestment"].to_f
      )
    else
      ytd = pull_actuals_for_year
      days_elapsed = Date.today.yday
      days_this_year = finalization_day.yday

      actuals =
        if Date.today >= finalization_day
          remaining_revenue_due_this_year =
            pull_outstanding_invoices.filter{|iv| (iv.due_date <= Date.today.end_of_year + 15.days) && iv.due_date >= Date.today.beginning_of_year}.map(&:balance).reduce(:+)
          ytd[:gross_revenue] += remaining_revenue_due_this_year
          ytd
        else
          {
            gross_payroll: (ytd[:gross_payroll] / days_elapsed) * days_this_year,
            gross_revenue: (ytd[:gross_revenue] / days_elapsed) * days_this_year,
            gross_benefits: (ytd[:gross_benefits] / days_elapsed) * days_this_year,
            gross_expenses: (ytd[:gross_expenses] / days_elapsed) * days_this_year,
            gross_subcontractors: (ytd[:gross_subcontractors] / days_elapsed) * days_this_year,
          }
        end

      # Override for projections
      actuals[:gross_revenue] = gross_revenue_override.to_f if gross_revenue_override.present?
      actuals[:gross_payroll] = gross_payroll_override.to_f if gross_payroll_override.present?
      actuals[:gross_benefits] = gross_benefits_override.to_f if gross_benefits_override.present?
      actuals[:gross_expenses] = gross_expenses_override.to_f if gross_expenses_override.present?
      actuals[:gross_subcontractors] = gross_subcontractors_override.to_f if gross_subcontractors_override.present?

      Stacks::ProfitShare::Scenario.new(
        actuals,
        total_psu_issued,
        self.prespent_profit_share,
        self.payroll_buffer_months,
        self.efficiency_cap,
        self.internals_budget_multiplier,
        projected_monthly_cost_of_doing_business,
        Stacks::ProfitShare::Scenario::FICA_TAX_RATE,
        total_reinvestment_spend("cash")
      )
    end
  end
end
