module Mcp
  class ExploreOkrTool < MCP::Tool
    tool_name 'explore_okr'
    description 'Per-OKR evidence drill-downs, mirroring the admin OKR Explorer: per-tracker ' \
                'margin/free-hours/satisfaction rows for successful_projects, per-lead proposal ' \
                'outcomes for successful_proposals, the per-person rate-to-hours utilization map ' \
                'for average_hourly_rate (deliberately exposed here and nowhere else), and the ' \
                'datapoint extras for the four client KPIs. Evidence for projects/proposals is ' \
                'computed live from the models, so period counts are kept small.'

    # The 7 datapoints with explorer pages (app/admin/okr_explorer.rb:8).
    OKRS = %w[
      average_hourly_rate successful_projects successful_proposals
      average_client_lifetime_value average_client_tenure
      client_revenue_concentration forecasted_sales_revenue
    ].freeze
    GRADATIONS = Studio::SNAPSHOT_GRADATIONS.map(&:to_s).freeze
    ACCOUNTING_METHODS = %w[cash accrual].freeze

    input_schema(
      properties: {
        studio: { type: 'string', description: 'Studio name or mini_name (case-insensitive). Required.' },
        okr: { type: 'string', description: "One of: #{OKRS.join(', ')}. Required." },
        gradation: { type: 'string', description: "#{GRADATIONS.join(', ')} (default month)" },
        accounting_method: { type: 'string', description: 'cash (default) or accrual' },
        periods: { type: 'integer', description: 'Most recent N periods (default 3, clamped 1..6 — evidence is computed live and is heavy)' },
      },
      required: %w[studio okr]
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(studio:, okr:, gradation: 'month', accounting_method: 'cash', periods: 3, server_context:)
      okr = okr.to_s
      unless OKRS.include?(okr)
        return Responses.error("Invalid okr '#{okr}'. Valid okrs: #{OKRS.join(', ')}")
      end
      gradation = gradation.to_s
      unless GRADATIONS.include?(gradation)
        return Responses.error("Invalid gradation '#{gradation}'. Valid gradations: #{GRADATIONS.join(', ')}")
      end
      method = accounting_method.to_s
      unless ACCOUNTING_METHODS.include?(method)
        return Responses.error("Invalid accounting_method '#{method}'. Valid: #{ACCOUNTING_METHODS.join(', ')}")
      end

      resolved = GetOkrGridTool.resolve_studio(studio, gradation)
      return resolved if resolved.is_a?(MCP::Tool::Response) # an error Response

      # Live Stacks::Period objects drive the rows (the evidence queries need
      # real date ranges); snapshot entries are joined on by label for the
      # period's headline value. Clamped low: these are heavy live queries.
      period_objs = Stacks::Period.for_gradation(gradation.to_sym).last(periods.to_i.clamp(1, 6))
      entries_by_label = Array(resolved.snapshot[gradation])
        .select { |e| e.is_a?(Hash) }
        .index_by { |e| e['label'] }

      # One batched query for all periods (studio.rb:311), not N heavy ones.
      trackers_by_period =
        okr == 'successful_projects' ? resolved.project_trackers_with_recorded_time_by_periods(period_objs) : nil

      rows = period_objs.filter_map do |period|
        entry = entries_by_label[period.label] || {}
        dp = entry.dig(method, 'datapoints', okr)
        {
          label: period.label,
          period_starts_at: period.starts_at.strftime('%m/%d/%Y'),
          period_ends_at: period.ends_at.strftime('%m/%d/%Y'),
          value: dp&.dig('value'),
          unit: dp&.dig('unit'),
          evidence: evidence_for(okr, resolved, period, entry, dp, trackers_by_period),
        }
      rescue StandardError => e
        Rails.logger.warn("[Mcp::ExploreOkrTool] skipping period '#{period.label}': #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        nil
      end

      Responses.ok({
        studio: resolved.name,
        mini_name: resolved.mini_name,
        okr: okr,
        gradation: gradation,
        accounting_method: method,
        periods: rows,
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ExploreOkrTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('explore_okr failed; the error was logged')
    end

    def self.evidence_for(okr, studio, period, entry, dp, trackers_by_period)
      case okr
      when 'successful_projects'
        # Mirrors the explorer's per-tracker table: live ProjectTracker reads
        # (each of these methods reads the tracker's own nightly snapshot).
        Array(trackers_by_period && trackers_by_period[period]).filter_map do |tracker|
          {
            tracker: tracker.name,
            url: tracker.external_link,
            profit_margin: tracker.profit_margin.to_f.round(2),
            spend: tracker.spend.to_f,
            estimated_cost: tracker.estimated_cost.to_f,
            total_hours: tracker.total_hours.to_f,
            total_free_hours: tracker.total_free_hours.to_f,
            free_hours_ratio: tracker.free_hours_ratio.to_f.round(4),
            client_satisfied: tracker.client_satisfied?,
            considered_successful: tracker.considered_successful?,
          }
        rescue StandardError => e
          Rails.logger.warn("[Mcp::ExploreOkrTool] skipping tracker id=#{tracker.id}: #{e.class}: #{e.message}")
          Sentry.capture_exception(e) if defined?(Sentry)
          nil
        end
      when 'successful_proposals'
        # Mirrors the explorer's per-lead table (studio.rb:369).
        studio.sent_proposals_settled_in_period(period).filter_map do |lead|
          {
            lead: lead.name,
            url: lead.notion_link,
            proposal_sent_at: lead.proposal_sent_at,
            settled_at: lead.settled_at,
            won_at: lead.won_at,
            considered_successful: lead.considered_successful?,
          }
        rescue StandardError => e
          Rails.logger.warn("[Mcp::ExploreOkrTool] skipping lead: #{e.class}: #{e.message}")
          Sentry.capture_exception(e) if defined?(Sentry)
          nil
        end
      when 'average_hourly_rate'
        # The one sanctioned surface for the snapshot's per-person
        # rate-to-hours utilization map — get_studio_health deliberately
        # strips it. Work-shaped data only: email, rate, hours sold.
        Hash(entry['utilization']).flat_map do |person, data|
          billable = data.is_a?(Hash) ? data['billable'] : nil
          next [] unless billable.is_a?(Hash)
          billable.map { |rate, hours| { person: person, rate: rate.to_f, hours: hours.to_f } }
        end
      else
        # The 4 client KPIs: the datapoint's extras verbatim.
        extras = dp&.dig('extras')
        extras.present? ? [extras] : []
      end
    end
  end
end
