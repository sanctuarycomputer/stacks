module Mcp
  class GetStudioHealthTool < MCP::Tool
    tool_name 'get_studio_health'
    description 'Per-studio health rollups from the nightly Studio snapshot: financial datapoints ' \
                '(income, cogs, net operating income, profit margin), utilization hours, lead counts, ' \
                'satisfaction scores, and OKR health per period. Pure read of the persisted rollup — ' \
                'figures always match Stacks\' own reporting. Never regenerates, never calls live APIs.'
    GRADATIONS = Studio::SNAPSHOT_GRADATIONS.map(&:to_s).freeze
    ACCOUNTING_METHODS = %w[cash accrual].freeze

    input_schema(
      properties: {
        studio: { type: 'string', description: 'Optional studio name or mini_name (case-insensitive). Default: all studios with a snapshot.' },
        gradation: { type: 'string', description: "#{GRADATIONS.join(', ')} (default month)" },
        accounting_method: { type: 'string', description: 'cash (default) or accrual' },
        periods: { type: 'integer', description: 'Most recent N periods (default 6, clamped 1..24)' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(studio: nil, gradation: 'month', accounting_method: 'cash', periods: 6, server_context:)
      gradation = gradation.to_s
      unless GRADATIONS.include?(gradation)
        return Responses.error("Invalid gradation '#{gradation}'. Valid gradations: #{GRADATIONS.join(', ')}")
      end
      method = accounting_method.to_s
      unless ACCOUNTING_METHODS.include?(method)
        return Responses.error("Invalid accounting_method '#{method}'. Valid: #{ACCOUNTING_METHODS.join(', ')}")
      end
      recent = periods.to_i.clamp(1, 24)

      all_studios = Studio.all.to_a
      requested =
        if studio.present?
          key = studio.to_s.strip
          # All studios the query could mean: exact name matches first (they
          # take priority when several have data), then mini_name-alias matches
          # (mini_name can hold a comma-separated list — see Studio's own
          # split(",")). Dedup preserves that priority order.
          candidates = (
            all_studios.select { |s| s.name.to_s.casecmp?(key) } +
            all_studios.select { |s| s.mini_name.to_s.split(',').map(&:strip).any? { |m| m.casecmp?(key) } }
          ).uniq
          if candidates.empty?
            valid = all_studios.map { |s| "#{s.name} (#{s.mini_name})" }.sort.join(', ')
            return Responses.error("Unknown studio '#{studio}'. Valid studios: #{valid}")
          end
          # Resolve to the highest-priority candidate that actually has data for
          # this gradation, so a data-carrying match is never shadowed by a
          # higher-priority but not-yet-snapshotted one. Only error when NONE
          # of the matches has a snapshot.
          match = candidates.find { |s| s.snapshot.present? && s.snapshot[gradation].present? }
          unless match
            return Responses.error("Studio '#{candidates.first.name}' has no generated snapshot for gradation '#{gradation}' yet.")
          end
          [match]
        else
          all_studios
        end

      studios_payload = requested.filter_map do |s|
        entries = s.snapshot.presence && s.snapshot[gradation]
        if entries.blank?
          Rails.logger.warn("[Mcp::GetStudioHealthTool] skipping studio '#{s.name}': no snapshot data for '#{gradation}'") if studio.blank?
          next nil
        end

        # Pass label/dates + the chosen accounting subtree (datapoints + okrs)
        # through VERBATIM — re-mapping invites drift from the canonical
        # computed shape. The period-level 'utilization' key is deliberately
        # excluded: it is a per-person email → hours map (get_capacity's
        # future surface), not a studio rollup.
        {
          studio: s.name,
          mini_name: s.mini_name,
          gradation: gradation,
          accounting_method: method,
          periods: Array(entries).last(recent).map do |entry|
            {
              label: entry['label'],
              period_starts_at: entry['period_starts_at'],
              period_ends_at: entry['period_ends_at'],
              datapoints: entry.dig(method, 'datapoints'),
              okrs: entry.dig(method, 'okrs'),
            }
          end,
        }
      rescue StandardError => e
        Rails.logger.warn("[Mcp::GetStudioHealthTool] skipping studio id=#{s.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        nil
      end

      if studio.present? && studios_payload.empty?
        return Responses.error("Studio '#{requested.first.name}' snapshot could not be read for gradation '#{gradation}' — it may be malformed. The failure was logged.")
      end

      Responses.ok({ studios: studios_payload })
    end
  end
end
