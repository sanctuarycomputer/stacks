class ProfitSharePass < ApplicationRecord
  MAX_LEADERSHIP_PSU = 240

  def self.this_year
    ProfitSharePass.all.select{|p| p.created_at.year == Time.now.year}
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

  def finalize!(scenario)
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
  end

  def self.ensure_exists!
    return ProfitSharePass.this_year.first if ProfitSharePass.this_year.any?
    ProfitSharePass.create!
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
      "datapoint" => :profit_margin,
      "okr" => g3d.ytd_snapshot.dig("accrual", "okrs_excluding_reinvestment", "Profit Margin"),
      "role_holders" => [*CollectiveRole.find_by(name: "General Manager").current_collective_role_holders]
    }, {
      "datapoint" => :revenue_growth,
      "okr" => g3d_ytd_revenue_growth_okr,
      "growth_progress" => g3d_ytd_revenue_growth_progress,
      "role_holders" => [*CollectiveRole.find_by(name: "General Manager").current_collective_role_holders]
    }, {
      "datapoint" => :successful_design_projects,
      "okr" => xxix.ytd_snapshot.dig("accrual", "okrs", "Successful Projects"),
      "role_holders" => [
        *CollectiveRole.find_by(name: "Creative Director").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Apprentice Creative Director").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Director of Project Delivery").current_collective_role_holders,
      ]
    }, {
      "datapoint" => :successful_development_projects,
      "okr" => sanctu.ytd_snapshot.dig("accrual", "okrs", "Successful Projects"),
      "role_holders" => [
        *CollectiveRole.find_by(name: "Technical Director").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Apprentice Technical Director").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Director of Project Delivery").current_collective_role_holders,
      ]
    }, {
      "datapoint" => :successful_design_proposals,
      "okr" => xxix.ytd_snapshot.dig("accrual", "okrs", "Successful Proposals"),
      "role_holders" => [
        *CollectiveRole.find_by(name: "Director of Business Development").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Creative Director").current_collective_role_holders,
      ]
    }, {
      "datapoint" => :successful_development_proposals,
      "okr" => sanctu.ytd_snapshot.dig("accrual", "okrs", "Successful Proposals"),
      "role_holders" => [
        *CollectiveRole.find_by(name: "Director of Business Development").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Technical Director").current_collective_role_holders
      ]
    }, {
      "datapoint" => :lead_growth,
      "okr" => g3d_ytd_lead_growth_okr,
      "growth_progress" => g3d_ytd_lead_growth_progress,
      "role_holders" => [
        *CollectiveRole.find_by(name: "Director of Business Development").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Director of Communications").current_collective_role_holders
      ]
    }, {
      "datapoint" => :workplace_satisfaction,
      "okr" => nil,
      "role_holders" => [
        *CollectiveRole.find_by(name: "Director of Project Delivery").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Director of People Ops").current_collective_role_holders
      ]
    }]

    collective_okrs.each do |dp|
      if dp["okr"].nil?
        dp["awarded_psu"] = 0
        next
      end

      dp["awarded_psu"] = Stacks::Utils.clamp(
        dp.dig("okr", "value"),
        dp.dig("okr", "target").to_f - dp.dig("okr", "tolerance").to_f,
        dp.dig("okr", "target").to_f + dp.dig("okr", "tolerance").to_f,
        0,
        (MAX_LEADERSHIP_PSU.to_f / collective_okrs.count)*2
      )
    end

    {
      "datapoints" => collective_okrs,
      "total_awarded" => collective_okrs.map{|dp| dp["awarded_psu"] }.reduce(&:+),
      "max" => MAX_LEADERSHIP_PSU
    }
  end

  def days_this_year
    created_at.end_of_year.yday
  end

  def leadership_psu_pool_awards_for_admin_user(admin_user, total_leadership_pool)
    # Check how many CollectiveRoles this individual has held this
    # year, and what percentage of the year it's been held * 10%
    collective_roles = CollectiveRoleHolderPeriod.where(admin_user: admin_user).map do |crhp|
      ended_at = crhp.period_ended_at || created_at.end_of_year
      next nil if ended_at < created_at.beginning_of_year
      next nil if crhp.period_started_at > created_at.end_of_year
      days_in_role_this_year = (crhp.period_started_at..ended_at.to_date).count
      award_percentage = (crhp.collective_role.name.downcase.include?("apprentice") ? 0.05 : 0.1) * (days_in_role_this_year / 366.0)

      {
        "collective_role_id" => crhp.collective_role.id,
        "days_in_role_this_year" => days_in_role_this_year,
        "award_percentage" => award_percentage,
        "awarded_psu" => award_percentage * total_leadership_pool
      }
    end

    project_leadership_roles = [
      *ProjectLeadPeriod.where(admin_user: admin_user)
    ].map do |prp|
      {
        "project_tracker_id" => prp.project_tracker_id,
        "role_type" => prp.class.to_s,
        "considered_successful?" => prp.project_tracker.considered_successful?,
      }
    end

    {
      "collective_roles" => collective_roles,
      "project_leadership_roles" => project_leadership_roles
    }
  end

  def payments(scenario = make_scenario)
    #return [] unless finalized? || (Date.today >= finalization_day)
    psu_value = scenario.actual_value_per_psu
    leadership_psu_pool_data = leadership_psu_pool

    Studio.garden3d.core_members_active_on(finalization_day).map do |a|
      psu_earnt = a.psu_earned_by(finalization_day)
      psu_earnt = 0 if psu_earnt == nil
      leadership_psu_breakdown = leadership_psu_pool_awards_for_admin_user(a, leadership_psu_pool_data["total_awarded"])
      leadership_psu_earnt = leadership_psu_breakdown["collective_roles"].map{|r| r["awarded_psu"].to_f}.reduce(&:+) || 0
      pre_spent_profit_share = a.pre_profit_share_spent_during(finalization_day.year)
      {
        admin_user: a,
        psu_value: psu_value,
        psu_earnt: psu_earnt,
        leadership_psu_breakdown: leadership_psu_breakdown,
        leadership_psu_earnt: leadership_psu_earnt,
        pre_spent_profit_share: pre_spent_profit_share,
        total_payout: (psu_value * psu_earnt) - pre_spent_profit_share
      }
    end
  end

  def total_psu_issued(psu_earned_by_date)
    if finalized?
      snapshot["inputs"]["total_psu_issued"].to_f
    else
      Studio.garden3d.core_members_active_on(finalization_day).map{|a| a.psu_earned_by(psu_earned_by_date) }.reject{|v| v == nil}.reduce(:+) || 0
    end
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
      ytd = Stacks::Profitability.pull_actuals_for_year(created_at.year)
      latest_month = Stacks::Profitability.pull_actuals_for_latest_month

      projected_monthly_cost_of_doing_business = (
        latest_month[:gross_payroll] +
        latest_month[:gross_expenses] +
        latest_month[:gross_benefits] +
        latest_month[:gross_subcontractors]
      )

      days_elapsed = Date.today.yday
      days_this_year = finalization_day.yday

      actuals =
        if Date.today >= finalization_day
          outstanding = Stacks::Profitability.pull_outstanding_invoices
          remaining_revenue_due_this_year =
            outstanding.filter{|iv| (iv.due_date <= Date.today.end_of_year + 15.days) && iv.due_date >= Date.today.beginning_of_year}.map(&:balance).reduce(:+)
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

      total_psu_issued = total_psu_issued((Date.new(Date.today.year, 12, 15)))

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
