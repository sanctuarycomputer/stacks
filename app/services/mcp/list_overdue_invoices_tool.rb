module Mcp
  class ListOverdueInvoicesTool < MCP::Tool
    tool_name 'list_overdue_invoices'
    description 'Overdue (unpaid or partially-paid) QBO invoices with days overdue, sorted ' \
                'most-overdue first, from already-synced rows. Never calls QBO live. Late fees ' \
                'are a per-client human decision — this tool exposes the data only.'
    input_schema(
      properties: {
        enterprise: { type: 'string', description: 'Optional enterprise name filter, e.g. "Sanctuary Computer Inc"' },
        min_days_overdue: { type: 'integer', description: 'Only invoices at least this many days overdue (default 1; minimum 1 — values below 1 are treated as 1)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(enterprise: nil, min_days_overdue: 1, server_context:)
      enterprises, error = QboReceivables.resolve_enterprises(enterprise)
      return Responses.error(error) if error

      as_of = Date.today
      min_days = [min_days_overdue.to_i, 1].max
      enterprise_names = enterprises.index_by(&:id)

      rows = QboReceivables.receivables(enterprises, as_of: as_of, details: true, min_days_overdue: min_days)

      invoices = rows
        .map do |r|
          {
            doc_number: r.doc_number,
            customer: r.customer || 'Unknown',
            customer_id: r.customer_id,
            enterprise: enterprise_names[r.enterprise_id].name,
            total: r.total,
            balance: r.balance,
            due_date: r.due_date.iso8601,
            days_overdue: r.days_overdue,
            status: r.status,
            qbo_invoice_link: r.qbo_invoice_link,
            display_name: r.display_name,
          }
        end
        .sort_by { |row| [-row[:days_overdue], row[:doc_number].to_s] }

      payload = { as_of: as_of.iso8601, count: invoices.length, invoices: invoices }
      Responses.ok(payload)
    end
  end
end
