ActiveAdmin.register_page "Dashboard" do
  menu label: "g3d", priority: 0

  controller do
    before_action :redirect_to_profile
    def redirect_to_profile
      unless current_admin_user.has_led_projects? || current_admin_user.is_admin?
        redirect_to admin_admin_user_path(current_admin_user)
      end
    end
  end

  content title: proc { I18n.t("active_admin.dashboard") } do
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
    ).deep_stringify_keys

    g3d_ytd_lead_growth_okr = g3d.ytd_snapshot.dig("accrual", "okrs_excluding_reinvestment", "Lead Growth")
    g3d_ytd_lead_growth_progress = Okr.make_annual_growth_progress_data(
      g3d_ytd_lead_growth_okr["target"].to_f.round(2),
      g3d_ytd_lead_growth_okr["tolerance"].to_f.round(2),
      g3d.last_year_snapshot.dig("accrual", "datapoints_excluding_reinvestment", "lead_count", "value"),
      g3d.ytd_snapshot.dig("accrual", "datapoints_excluding_reinvestment", "lead_count", "value"),
      :count
    ).deep_stringify_keys

    collective_okrs = [{
      "datapoint" => "profit_margin",
      "okr" => g3d.ytd_snapshot.dig("accrual", "okrs_excluding_reinvestment", "Profit Margin"),
    }, {
      "datapoint" => "revenue_growth",
      "okr" => g3d_ytd_revenue_growth_okr,
      "growth_progress" => g3d_ytd_revenue_growth_progress,
    }, {
      "datapoint" => "successful_design_projects",
      "okr" => xxix.ytd_snapshot.dig("accrual", "okrs", "Successful Projects"),
    }, {
      "datapoint" => "successful_development_projects",
      "okr" => sanctu.ytd_snapshot.dig("accrual", "okrs", "Successful Projects"),
    }, {
      "datapoint" => "successful_design_proposals",
      "okr" => xxix.ytd_snapshot.dig("accrual", "okrs", "Successful Proposals"),
    }, {
      "datapoint" => "successful_development_proposals",
      "okr" => sanctu.ytd_snapshot.dig("accrual", "okrs", "Successful Proposals"),
    }, {
      "datapoint" => "lead_growth",
      "okr" => g3d_ytd_lead_growth_okr,
      "growth_progress" => g3d_ytd_lead_growth_progress,
    }, {
      "datapoint" => "workplace_satisfaction",
      "okr" => g3d.ytd_snapshot.dig("accrual", "okrs_excluding_reinvestment", "Workplace Satisfaction"),
    }]

    accounting_method = session[:accounting_method] || "cash"
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
          report.find_row(accounting_method, "Total Expenses")
        )
      end
    average_burn_rate = burn_rates.sum(0.0) / burn_rates.length

    render(partial: "dashboard", locals: {
      g3d: g3d,
      collective_okrs: collective_okrs,
      accounts: cc_or_bank_accounts.map do |a|
        OpenStruct.new({
          name: a.name,
          classification: a.classification,
          current_balance: a.current_balance
        })
      end,
      aggregated_new_deal_balance: Contributor.aggregated_new_deal_balance,
      runway_data: {
        net_cash: net_cash,
        average_burn_rate: average_burn_rate,
      },
    })
  end
end
