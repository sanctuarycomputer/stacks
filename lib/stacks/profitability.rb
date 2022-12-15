# TODO: move me to Quickbooks?
class Stacks::Profitability
  class << self
    def pull_outstanding_invoices
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      invoice_service = Quickbooks::Service::Invoice.new
      invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      invoice_service.access_token = access_token
      invoice_service.query("Select * From Invoice Where Balance > '0.0'")
    end

    def pull_actuals_for_year(year)
      qbo_access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token
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

    def pull_actuals_for_month(date = Date.today)
      qbo_access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token
      report_service = Quickbooks::Service::Reports.new
      report_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      report_service.access_token = qbo_access_token

      report = report_service.query("ProfitAndLoss", nil, {
        start_date: date.beginning_of_month.strftime("%Y-%m-%d"),
        end_date: date.end_of_month.strftime("%Y-%m-%d"),
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
      if Date.today.month == 1
        return {
          gross_revenue: 0,
          gross_payroll: 0,
          gross_benefits: 0,
          gross_subcontractors: 0,
          gross_expenses: 0
        }
      end

      qbo_access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token
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
  end
end
