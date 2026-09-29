module Mcp
  class ListOverdueInvoicesTool < MCP::Tool
    tool_name 'list_overdue_invoices'
    description 'Overdue (unpaid or partially-paid) QBO invoices with days overdue, sorted ' \
                'most-overdue first, from already-synced rows. Never calls QBO live. Late fees ' \
                'are a per-client human decision — this tool exposes the data only. project_trackers: the ' \
                'project trackers each invoice bills (via its invoice tracker); empty for ad hoc invoices.'
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
      trackers = project_trackers_by_invoice(rows.map(&:invoice_id))

      invoices = rows
        .map do |r|
          {
            doc_number: r.doc_number,
            customer: r.customer || 'Unknown',
            customer_id: r.customer_id.presence, # blank ids emit as null, matching get_ar_aging
            enterprise: enterprise_names[r.enterprise_id].name,
            total: r.total,
            balance: r.balance,
            due_date: r.due_date.iso8601,
            days_overdue: r.days_overdue,
            status: r.status,
            qbo_invoice_link: r.qbo_invoice_link,
            display_name: r.display_name,
            project_trackers: trackers.fetch(r.invoice_id, []),
          }
        end
        .sort_by { |row| [-row[:days_overdue], row[:doc_number].to_s] }

      payload = { as_of: as_of.iso8601, count: invoices.length, invoices: invoices }
      Responses.ok(payload)
    end

    # QboInvoice row id → [{ id, name }] of the project trackers it bills: the InvoiceTracker holding the
    # invoice's exact (qbo_account_id, qbo_id) pair, then that tracker's blueprint forecast projects. An ad hoc
    # invoice (no InvoiceTracker) maps to nothing. Read-only, a fixed number of queries whatever the row count.
    def self.project_trackers_by_invoice(invoice_ids)
      pairs = QboInvoice.where(id: invoice_ids).pluck(:id, :qbo_account_id, :qbo_id)
      return {} if pairs.empty?

      id_by_pair = pairs.to_h { |id, qa, qid| [[qa, qid], id] }
      candidates = InvoiceTracker.where(qbo_invoice_id: pairs.map(&:last).uniq, qbo_account_id: pairs.map { |p| p[1] }.uniq).to_a
      invoice_trackers = candidates.select { |t| id_by_pair.key?([t.qbo_account_id, t.qbo_invoice_id]) }
      InvoiceTracker.batch_preload_project_trackers!(invoice_trackers)
      invoice_trackers.each_with_object(Hash.new { |h, k| h[k] = [] }) do |t, out|
        out[id_by_pair[[t.qbo_account_id, t.qbo_invoice_id]]].concat(t.project_trackers.map { |pt| { id: pt.id, name: pt.name } })
      end.transform_values(&:uniq)
    end
    private_class_method :project_trackers_by_invoice
  end
end
