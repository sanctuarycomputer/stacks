module Mcp
  class GetClientRevenueTool < MCP::Tool
    tool_name 'get_client_revenue'
    description 'Per-client invoiced revenue by month, the rows the Client Services close ' \
                'report narrates: client x month amounts (zero-filled across the window), ' \
                'window totals, share-of-total percentages, and a month-over-month total ' \
                'series. Scope: EXTERNAL clients only; countable revenue = invoice trackers ' \
                'with a linked, non-voided synced QBO invoice; the requested window governs ' \
                'which months appear (no fixed historical cutoff). Rows group by client NAME, ' \
                'so duplicate-named ForecastClients merge into one row — the concentration ' \
                'OKR datapoint groups by client record and can differ. The default garden3d ' \
                'view counts full invoice totals; passing a sub-studio takes its pro-rata ' \
                'share via blueprint person lines (trackers without usable lines are omitted ' \
                'from sub-studio numbers). Months follow each invoice pass, not payment ' \
                'dates. Reads stored invoice data only; blank mirrors are skipped and counted ' \
                'in skipped_tracker_count (an all-time count, not window-scoped). Trackers ' \
                'whose stored invoice data is malformed (e.g. sent with no due_date) are ' \
                'likewise skipped and counted — get_invoice_passes buckets the same row as ' \
                'status unknown and still counts its total.'

    SCOPE_NOTE = 'External clients only; countable revenue = invoice trackers with a linked, ' \
                 'non-voided synced QBO invoice, attributed to the month of their invoice pass. ' \
                 'garden3d counts full invoice totals; sub-studios take a pro-rata share via ' \
                 'blueprint person lines.'.freeze

    MIN_MONTHS_BACK = 1
    MAX_MONTHS_BACK = 24
    DEFAULT_MONTHS_BACK = 6
    MIN_TOP = 1
    MAX_TOP = 50
    DEFAULT_TOP = 15

    input_schema(
      properties: {
        months_back: { type: 'integer', description: "Trailing months (default #{DEFAULT_MONTHS_BACK}, clamped #{MIN_MONTHS_BACK}..#{MAX_MONTHS_BACK})." },
        top: { type: 'integer', description: "How many clients, by window total desc (default #{DEFAULT_TOP}, clamped #{MIN_TOP}..#{MAX_TOP}). Window totals still cover every client." },
        studio: { type: 'string', description: 'Optional studio name or mini_name (case-insensitive). Default garden3d — full invoice totals; sub-studios get their blueprint pro-rata share.' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(months_back: DEFAULT_MONTHS_BACK, top: DEFAULT_TOP, studio: nil, server_context:)
      months_back = months_back.to_i.clamp(MIN_MONTHS_BACK, MAX_MONTHS_BACK)
      top = top.to_i.clamp(MIN_TOP, MAX_TOP)

      all_studios = Studio.all.to_a
      resolved = resolve_studio(studio, all_studios)
      return resolved if resolved.is_a?(MCP::Tool::Response) # error envelope

      # One instance per call, deliberately un-memoized (see
      # Studio#client_revenue): its constructor builds the full Row set with
      # the same stored-attribute-only guard the nightly snapshot relies on.
      revenue = Stacks::ClientRevenue.new(resolved, all_studios)

      months = window_months(months_back)
      in_window = revenue.rows.select { |r| months.first <= r.month && r.month <= months.last }
      by_client = in_window.group_by { |r| r.client.name }
      totals = by_client.transform_values { |rs| rs.sum(&:amount) }
      window_total = totals.values.sum

      clients = totals
        .sort_by { |name, total| [-total, name] }
        .first(top)
        .map do |name, total|
          amounts_by_month = by_client[name].group_by(&:month).transform_values { |rs| rs.sum(&:amount) }
          {
            client: name,
            monthly: months.map { |m| { month: m.iso8601, amount: amounts_by_month.fetch(m, 0.0).round(2) } },
            total: total.round(2),
            share_of_total_pct: window_total.zero? ? nil : ((total / window_total) * 100).round(1),
          }
        end

      mom = in_window.group_by(&:month).transform_values { |rs| rs.sum(&:amount) }

      Responses.ok({
        as_of: Date.today.iso8601,
        studio: resolved.name,
        months_back: months_back,
        scope: SCOPE_NOTE,
        clients: clients,
        client_count: by_client.length,
        total_revenue: window_total.round(2),
        mom_totals: months.map { |m| { month: m.iso8601, total: mom.fetch(m, 0.0).round(2) } },
        skipped_tracker_count: revenue.skipped_tracker_count,
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetClientRevenueTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_client_revenue failed; the error was logged')
    end

    # Same resolution get_studio_health uses: exact name matches, then
    # mini_name matches. Default is garden3d (the full-invoice-total view).
    def self.resolve_studio(studio, all_studios)
      if studio.blank?
        g3d = all_studios.find(&:is_garden3d?)
        return g3d if g3d
        return Responses.error('No garden3d studio exists; pass a studio explicitly.')
      end

      key = studio.to_s.strip
      found =
        all_studios.find { |s| s.name.to_s.casecmp?(key) } ||
        all_studios.find { |s| s.mini_name.to_s.split(',').map(&:strip).any? { |m| m.casecmp?(key) } }
      return found if found

      valid = all_studios.map { |s| "#{s.name} (#{s.mini_name})" }.sort.join(', ')
      Responses.error("Unknown studio '#{studio}'. Valid studios: #{valid}")
    end

    def self.window_months(months_back)
      start = Date.today.beginning_of_month - (months_back - 1).months
      (0...months_back).map { |i| start + i.months }
    end
  end
end
