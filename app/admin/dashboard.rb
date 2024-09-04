ActiveAdmin.register_page "Dashboard" do
  menu label: "Runway", parent: "Money"

  content title: proc { I18n.t("active_admin.dashboard") } do
    COLORS = Stacks::Utils::COLORS
    accounting_method = session[:accounting_method] || "cash"

    g3d = Studio.garden3d
    collective_okrs = [{
      datapoint: :profit_margin,
      okr: g3d.ytd_snapshot.dig("accrual", "okrs_excluding_reinvestment", "Profit Margin"),
      role_holders: [*CollectiveRole.find_by(name: "General Manager").current_collective_role_holders]
    }, {
      datapoint: :revenue_growth,
      okr: nil,
      role_holders: [*CollectiveRole.find_by(name: "General Manager").current_collective_role_holders]
    }, {
      datapoint: :successful_design_projects,
      okr: nil,
      role_holders: [
        *CollectiveRole.find_by(name: "Creative Director").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Apprentice Creative Director").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Director of Project Delivery").current_collective_role_holders,
      ]
    }, {
      datapoint: :successful_development_projects,
      okr: nil,
      role_holders: [
        *CollectiveRole.find_by(name: "Technical Director").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Apprentice Technical Director").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Director of Project Delivery").current_collective_role_holders,
      ]
    }, {
      datapoint: :successful_new_business_proposals,
      okr: nil,
      role_holders: [
        *CollectiveRole.find_by(name: "Director of Business Development").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Creative Director").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Technical Director").current_collective_role_holders
      ]
    }, {
      datapoint: :new_business_lead_growth,
      okr: nil,
      role_holders: [
        *CollectiveRole.find_by(name: "Director of Business Development").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Director of Communications").current_collective_role_holders
      ]
    }, {
      datapoint: :workplace_satisfaction,
      okr: nil,
      role_holders: [
        *CollectiveRole.find_by(name: "Director of Project Delivery").current_collective_role_holders,
        *CollectiveRole.find_by(name: "Director of People Ops").current_collective_role_holders
      ]
    }]

    qbo_accounts = Stacks::Quickbooks.fetch_all_accounts
    cc_or_bank_accounts = qbo_accounts.select do |a|
      ["Bank", "Credit Card"].include?(a.account_type)
    end

    net_cash = cc_or_bank_accounts.map do |a|
      if a.classification == "Liability"
        -1 * a.current_balance.abs
      else
        a.current_balance
      end
    end.reduce(:+)

    burn_rates =
      [1, 2, 3].map do |month|
        report = QboProfitAndLossReport.find_or_fetch_for_range(
          (Date.today - month.months).beginning_of_month,
          (Date.today - month.months).end_of_month,
          false,
          nil
        )

        (
          report.find_row(accounting_method, "Total Cost of Goods Sold") +
          report.find_row(accounting_method, "Total Expenses") -
          report.find_row(accounting_method, "[SC] Reinvestment Profit Share, Bonuses & Misc")
        )
      end
    average_burn_rate = burn_rates.sum(0.0) / burn_rates.length

    all_psp = ProfitSharePass.finalized.order(created_at: :asc).all
    g3d_over_time_data = {
      labels: all_psp.map{|psp| psp.created_at.year.to_s},
      datasets: []
    }

    case params["g3d"]
    when nil, "psu"
      g3d_over_time_data[:datasets] << {
        label: 'PSU Value (USD)',
        backgroundColor: Stacks::Utils::COLORS,
        data: (all_psp.map do |psp|
          psp.make_scenario.actual_value_per_psu
        end)
      }
    when "psp"
      g3d_over_time_data[:datasets] << {
        label: 'Profit Share Pool (USD)',
        backgroundColor: Stacks::Utils::COLORS,
        data: (all_psp.map do |psp|
          psp.make_scenario.allowances[:pool_after_fica_withholding]
        end)
      }
    when "revenue"
      g3d_over_time_data[:datasets] << {
        label: 'Revenue',
        backgroundColor: Stacks::Utils::COLORS,
        data: (all_psp.map do |psp|
          psp.make_scenario.actuals[:gross_revenue]
        end)
      }
    when "margin"
      g3d_over_time_data[:datasets] << {
        label: 'Profit Margin (%)',
        backgroundColor: Stacks::Utils::COLORS,
        data: (all_psp.map do |psp|
          (psp.make_scenario.raw_efficiency * 100) - 100
        end)
      }
    else
    end

    render(partial: "dashboard", locals: {
      g3d: g3d,
      collective_okrs: collective_okrs,
      accounts: cc_or_bank_accounts,
      runway_data: {
        net_cash: net_cash,
        average_burn_rate: average_burn_rate
      },
      g3d_over_time_data: g3d_over_time_data,
    })
  end
end
