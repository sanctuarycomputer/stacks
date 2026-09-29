module Mcp
  class GetFinancialOutlookTool < MCP::Tool
    tool_name 'get_financial_outlook'
    description 'The company-wide financial outlook (one company: never split by studio or enterprise). ' \
                'booked: the next months of the Runn plan, priced as booked hours × project rate before ' \
                'discounts/caps (time-and-materials only; fixed-price projects are listed with their budget, not ' \
                'priced hourly; non-billable work excluded); retainers capped at their monthly budget; placeholders ' \
                'and unconfirmed projects shown separately as tentative; top projects per month. ' \
                'actuals: Income for the last closed months, accrual basis (QBO P&L). target: the Income OKR ' \
                'target if one is stored (never assumed). spend: company-wide spend by expense category (accrual, ' \
                'QBO P&L, every entity combined), last months vs the months before, with top movers; payroll, ' \
                'benefits, contractors, payments to people and intercompany are excluded. Cash and runway are ' \
                'cash-basis and live in get_executive_dashboard. Every figure ' \
                'carries its basis label. Aggregates only: no person is ever named.'

    input_schema(
      properties: {
        months: { type: 'integer', description: 'How many months ahead (booked) and back (actuals, spend). Default 3, max 6.' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(months: 3, server_context:)
      Responses.ok(Stacks::FinancialOutlook.new(months: months).call)
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetFinancialOutlookTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_financial_outlook failed; the error was logged')
    end
  end
end
