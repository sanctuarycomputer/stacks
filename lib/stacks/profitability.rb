class Stacks::Profitability
  class << self
    STUDIO_MAPPING = {
      sanctu: "Development",
      hydro: "Product Design",
      xxix: "Brand Design",
      index: "Community",
      support: "Operations",
    }

    def pull_actuals_for_year(year)
      qbo_access_token = Stacks::Automator.make_and_refresh_qbo_access_token
      report_service = Quickbooks::Service::Reports.new
      report_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      report_service.access_token = qbo_access_token

      time = DateTime.parse("1st Jan #{year}")
      report = report_service.query("ProfitAndLoss", nil, {
        start_date: time.strftime("%Y-%m-%d"),
        end_date: time.end_of_year.strftime("%Y-%m-%d"),
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

    def pull_actuals_for_latest_month
      qbo_access_token = Stacks::Automator.make_and_refresh_qbo_access_token
      report_service = Quickbooks::Service::Reports.new
      report_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      report_service.access_token = qbo_access_token

      latest_full_month = Date.new(Date.today.year, Date.today.month - 1, 1)
      report = report_service.query("ProfitAndLoss", nil, {
        start_date: latest_full_month.beginning_of_month.strftime("%Y-%m-%d"),
        end_date: latest_full_month.end_of_month.strftime("%Y-%m-%d"),
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

    def make_actuals_projections(profitability_pass, year = Time.now.year)
      latest_data =
        profitability_pass.data["garden3d"][year.to_s]
      ytd = latest_data.values.reduce({}) do |acc, v|
        acc["gross_payroll"] =
          (acc["gross_payroll"] || 0.0) + (v["gross_payroll"].to_f || 0.0)
        acc["gross_revenue"] =
          (acc["gross_revenue"] || 0.0) + (v["gross_revenue"].to_f || 0.0)
        acc["gross_benefits"] =
          (acc["gross_benefits"] || 0.0) + (v["gross_benefits"].to_f || 0.0)
        acc["gross_expenses"] =
          (acc["gross_expenses"] || 0.0) + (v["gross_expenses"].to_f || 0.0)
        acc["gross_subcontractors"] =
          (acc["gross_subcontractors"] || 0.9) + (v["gross_subcontractors"].to_f || 0.0)
        acc
      end

      months_passed = latest_data.keys.length
      {
        "gross_payroll": (ytd["gross_payroll"] / months_passed) * 12,
        "gross_revenue": (ytd["gross_revenue"] / months_passed) * 12,
        "gross_benefits": (ytd["gross_benefits"] / months_passed) * 12,
        "gross_expenses": (ytd["gross_expenses"] / months_passed) * 12,
        "gross_subcontractors": (ytd["gross_subcontractors"] / months_passed) * 12,
      }
    end

    def calculate
      qbo_access_token = Stacks::Automator.make_and_refresh_qbo_access_token
      report_service = Quickbooks::Service::Reports.new
      report_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      report_service.access_token = qbo_access_token

      data = { garden3d: {} }

      time_start = DateTime.parse("1st Jan 2020")
      time_end = 0.seconds.ago
      time = time_start
      while time < time_end
        report = report_service.query("ProfitAndLoss", nil, {
          start_date: time.strftime("%Y-%m-%d"),
          end_date: time.strftime("%Y-%m-#{time.end_of_month.day}"),
        })

        year_as_sym = time.strftime("%Y").to_sym
        month_as_sym = time.strftime("%B").downcase.to_sym

        data[:garden3d][year_as_sym] =
          data[:garden3d][year_as_sym] || {}
        data[:garden3d][year_as_sym][month_as_sym] =
          data[:garden3d][year_as_sym][month_as_sym] || {}

        data[:garden3d][year_as_sym][month_as_sym][:gross_revenue] =
          (report.find_row("Total Income").try(:[], 1) || 0)
        data[:garden3d][year_as_sym][month_as_sym][:gross_payroll] =
          (report.find_row("Total [SC] Payroll").try(:[], 1) || 0)
        data[:garden3d][year_as_sym][month_as_sym][:gross_benefits] =
          (report.find_row("Total [SC] Benefits, Contributions & Tax").try(:[], 1) || 0)
        data[:garden3d][year_as_sym][month_as_sym][:gross_subcontractors] =
          (report.find_row("Total [SC] Subcontractors").try(:[], 1) || 0)
        data[:garden3d][year_as_sym][month_as_sym][:gross_expenses] = (
          (report.find_row("Total Expenses").try(:[], 1) || 0) +
          (report.find_row("Total [SC] Supplies & Materials").try(:[], 1) || 0)
        )

        STUDIO_MAPPING.keys.each do |studio|
          data[studio] = data[studio] || {}
          data[studio][year_as_sym] = data[studio][year_as_sym] || {}
          data[studio][year_as_sym][month_as_sym] = data[studio][year_as_sym][month_as_sym] || {}
          token = STUDIO_MAPPING[studio]

          data[studio][year_as_sym][month_as_sym][:gross_revenue] =
            (report.find_row("[SC] #{token} Services").try(:[], 1) || 0)
          data[studio][year_as_sym][month_as_sym][:gross_payroll] =
            (report.find_row("[SC] #{token} Payroll").try(:[], 1) || 0)
          data[studio][year_as_sym][month_as_sym][:gross_benefits] =
            (report.find_row("[SC] #{token} Benefits, Contributions & Tax").try(:[], 1) || 0)
          data[studio][year_as_sym][month_as_sym][:gross_subcontractors] =
            (report.find_row("[SC] #{token} Subcontractors").try(:[], 1) || 0)
          if data[:garden3d][year_as_sym][month_as_sym][:gross_revenue] > 0
            data[studio][year_as_sym][month_as_sym][:gross_expenses] =
              ((data[studio][year_as_sym][month_as_sym][:gross_revenue] / data[:garden3d][year_as_sym][month_as_sym][:gross_revenue]) * data[:garden3d][year_as_sym][month_as_sym][:gross_expenses]) + (report.find_row("[SC] #{token} Supplies & Materials").try(:[], 1) || 0)
          else
            data[studio][year_as_sym][month_as_sym][:gross_expenses] = 0
          end
        end

        time = time.advance(months: 1)
      end

      new_profitability_pass = ProfitabilityPass.create!(data: data)
      ProfitabilityPass.where.not(id: new_profitability_pass.id).delete_all
    end
  end
end
