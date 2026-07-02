module Mcp
  class ListOverdueInvoicesTool < MCP::Tool
    tool_name 'list_overdue_invoices'
    description 'Overdue (unpaid or partially-paid) QBO invoices with days overdue, sorted ' \
                'most-overdue first, from already-synced rows. Never calls QBO live. Late fees ' \
                'are a per-client human decision — this tool exposes the data only.'
    input_schema(
      properties: {
        enterprise: { type: 'string', description: 'Optional enterprise name filter, e.g. "Sanctuary Computer Inc"' },
        min_days_overdue: { type: 'integer', description: 'Only invoices at least this many days overdue (default 1)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    OVERDUE_STATUSES = %i[unpaid_overdue partially_paid_overdue].freeze

    def self.call(enterprise: nil, min_days_overdue: 1, server_context:)
      enterprises, error = QboReceivables.resolve_enterprises(enterprise)
      return QboReceivables.error_response(error) if error

      as_of = Date.today
      invoices = enterprises.flat_map do |ent|
        QboReceivables.receivables(ent).filter_map do |inv|
          next unless OVERDUE_STATUSES.include?(inv.status)
          days = QboReceivables.days_overdue(inv, as_of)
          next if days < min_days_overdue.to_i
          {
            doc_number: inv.data['doc_number'],
            customer: inv.customer_ref['name'] || 'Unknown',
            enterprise: ent.name,
            total: inv.total,
            balance: inv.balance,
            due_date: inv.due_date.iso8601,
            days_overdue: days,
            status: inv.status,
            qbo_invoice_link: inv.qbo_invoice_link,
            display_name: inv.display_name,
          }
        rescue StandardError
          nil # malformed synced row — skip it, never fail the whole report
        end
      end.sort_by { |row| [-row[:days_overdue], row[:doc_number].to_s] }

      payload = { as_of: as_of.iso8601, count: invoices.length, invoices: invoices }
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
