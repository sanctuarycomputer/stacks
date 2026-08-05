module Mcp
  class GetInvoicePassesTool < MCP::Tool
    tool_name 'get_invoice_passes'
    description 'Monthly invoicing passes as the admin Invoicing surface shows them: for each ' \
                'monthly pass, invoiced totals / invoice counts / invoice-status mix per legal ' \
                'entity (attributed by each invoice tracker\'s issuing QBO account), whether ' \
                'the pass completed or is stuck on missing hours, plus a month-over-month ' \
                'total-invoiced series. Totals mirror the admin value column (every linked ' \
                'invoice counts; the status mix separates voided/unpaid/paid). Reads STORED ' \
                'QBO invoice data only — mirrors with no synced data yet are skipped and ' \
                'counted per entity, never fetched live.'

    MIN_MONTHS_BACK = 1
    MAX_MONTHS_BACK = 24
    DEFAULT_MONTHS_BACK = 6

    input_schema(
      properties: {
        months_back: { type: 'integer', description: "Trailing months of passes (default #{DEFAULT_MONTHS_BACK}, clamped #{MIN_MONTHS_BACK}..#{MAX_MONTHS_BACK})." },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(months_back: DEFAULT_MONTHS_BACK, server_context:)
      months_back = months_back.to_i.clamp(MIN_MONTHS_BACK, MAX_MONTHS_BACK)
      window_start = Date.today.beginning_of_month - (months_back - 1).months

      passes = InvoicePass
        .where('start_of_month >= ?', window_start)
        .order(:start_of_month)
        .includes(invoice_trackers: [:qbo_invoice, { qbo_account: :enterprise }])
        .map { |pass| pass_block(pass) }

      Responses.ok({
        as_of: Date.today.iso8601,
        months_back: months_back,
        passes: passes,
        mom: passes.map { |p| { month: p[:month], total_invoiced: p[:total_invoiced] } },
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetInvoicePassesTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_invoice_passes failed; the error was logged')
    end

    def self.pass_block(pass)
      entities = pass.invoice_trackers
        .group_by { |t| t.qbo_account&.enterprise&.name || 'Unknown entity' }
        .sort_by { |name, _| name }
        .map { |name, trackers| entity_block(name, trackers) }

      {
        month: pass.start_of_month.iso8601,
        label: pass.invoice_month,
        completed_at: pass.completed_at&.iso8601,
        missing_hours: missing_hours?(pass),
        total_invoiced: entities.sum { |e| e[:invoiced_total] }.round(2),
        entities: entities,
      }
    end

    # NEVER InvoicePass#value / #statuses here — both walk each tracker into
    # QboInvoice#data, whose blank-data path live-syncs (and can destroy the
    # row, hazard H1/H3-adjacent). Totals and statuses come from stored
    # attributes only, IncomeSeries-style: blank stored data → skip + count.
    def self.entity_block(entity_name, trackers)
      skipped = 0
      invoiced_total = 0.0
      invoice_count = 0
      status_mix = Hash.new(0)

      trackers.each do |tracker|
        invoice = tracker.qbo_invoice
        if invoice.nil?
          # InvoiceTracker#status semantics without touching the invoice path.
          status_mix[tracker.blueprint.nil? ? 'not_made' : 'deleted'] += 1
          next
        end
        if invoice.read_attribute(:data).blank?
          skipped += 1
          next
        end

        invoiced_total += invoice.read_attribute(:data)['total'].to_f
        invoice_count += 1
        # Stored data is present, so #status reads the stored jsonb (no lazy
        # sync). It can still raise on malformed rows (e.g. EmailSent with no
        # due_date): count those as unknown rather than dropping their total.
        status = begin
          invoice.status.to_s
        rescue StandardError
          'unknown'
        end
        status_mix[status] += 1
      rescue StandardError => e
        Rails.logger.warn("[Mcp::GetInvoicePassesTool] skipping tracker id=#{tracker.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        skipped += 1
      end

      {
        entity: entity_name,
        invoiced_total: invoiced_total.round(2),
        invoice_count: invoice_count,
        status_mix: status_mix,
        skipped_invoices: skipped,
      }
    end

    # Mirrors InvoicePass#statuses' :missing_hours branch without calling it
    # (the other branch of #statuses walks tracker → invoice → lazy #data).
    def self.missing_hours?(pass)
      (pass.data || {})['reminder_passes'].present? && pass.latest_reminder_pass.present?
    rescue StandardError
      false
    end
  end
end
