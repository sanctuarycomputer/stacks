module ProjectTrackers
  # The cumulative invoiced-income series for the budget burn-up chart —
  # extracted from the admin show page so /admin/project_trackers and the
  # MCP burn-up tool share one source of truth. Generated + adhoc invoice
  # trackers with a synced QBO invoice, ordered by the invoice's due_date
  # (falling back to the tracker row's created_at), seeded with a zero
  # point at the first recorded assignment date. InvoiceTrackers are
  # client-level, so only line items attributable to this tracker's
  # forecast projects count; adhoc invoices belong to this tracker
  # outright, so their whole total counts.
  #
  # HAZARD: QboInvoice#data live-fetches via sync! when the stored jsonb is
  # blank — and sync! can update! or even DESTROY the row. This service
  # therefore reads ONLY the stored attribute (read_attribute(:data)):
  # invoices whose stored data is blank are skipped and counted in
  # :skipped_invoices, never lazily synced. (Rows that survive the guard
  # have present stored data, so downstream #data readers — line_items,
  # total — return the stored jsonb and can never hit the lazy path.)
  #
  # Returns { income: [{ x:, y: }, ...], income_total: Float,
  #           skipped_invoices: Integer }.
  class IncomeSeries
    def self.call(tracker)
      new(tracker).call
    end

    def initialize(tracker)
      @tracker = tracker
    end

    def call
      rows = [
        *@tracker.invoice_trackers,
        *@tracker.adhoc_invoice_trackers
      ].reject { |it| it.qbo_invoice.nil? }
      rows, unsynced = rows.partition { |it| stored_data(it.qbo_invoice).present? }

      series = rows
        .sort_by { |it| due_date_for(it) }
        .reduce({
          income: [{
            x: seed_date,
            y: 0
          }],
          income_total: 0
        }) do |acc, it|
          acc[:income].push({
            x: due_date_for(it),
            y: acc[:income_total] += amount_for(it)
          })
          acc
        end

      series[:skipped_invoices] = unsynced.length
      series
    end

    private

    def seed_date
      @tracker.first_recorded_assignment_start_date&.iso8601 || DateTime.now.iso8601
    end

    # Stored jsonb only — never QboInvoice#data, whose blank-data lazy path
    # live-syncs (and can destroy the row).
    def stored_data(qbo_invoice)
      qbo_invoice.read_attribute(:data) || {}
    end

    def due_date_for(it)
      stored_data(it.qbo_invoice)["due_date"] || it.created_at.to_date.iso8601
    end

    def amount_for(it)
      if it.is_a?(InvoiceTracker)
        it.qbo_line_items_relating_to_forecast_projects(@tracker.forecast_projects)
          .map { |qbo_li| qbo_li.dig("amount").to_f }
          .reduce(&:+) || 0
      else
        stored_data(it.qbo_invoice)["total"].to_f
      end
    end
  end
end
