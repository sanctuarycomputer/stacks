module Mcp
  class GetOkrGridTool < MCP::Tool
    tool_name 'get_okr_grid'
    description 'The studio OKR grid from the nightly Studio snapshot: every OKR row (including ' \
                'the synthetic Profit / Surplus Profit rows) across the requested periods, with ' \
                'value/target/tolerance/health/surplus/hint per cell. target is absent when no ' \
                'value was measurable for the period; synthetic rows carry no tolerance. The grid ' \
                'transposition (okr_names x periods) is left to the consumer.'
    GRADATIONS = Studio::SNAPSHOT_GRADATIONS.map(&:to_s).freeze
    ACCOUNTING_METHODS = %w[cash accrual].freeze

    input_schema(
      properties: {
        studio: { type: 'string', description: 'Studio name or mini_name (case-insensitive). Required.' },
        gradation: { type: 'string', description: "#{GRADATIONS.join(', ')} (default month)" },
        accounting_method: { type: 'string', description: 'cash (default) or accrual' },
        periods: { type: 'integer', description: 'Most recent N periods (default 6, clamped 1..24)' },
      },
      required: ['studio']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(studio:, gradation: 'month', accounting_method: 'cash', periods: 6, server_context:)
      gradation = gradation.to_s
      unless GRADATIONS.include?(gradation)
        return Responses.error("Invalid gradation '#{gradation}'. Valid gradations: #{GRADATIONS.join(', ')}")
      end
      method = accounting_method.to_s
      unless ACCOUNTING_METHODS.include?(method)
        return Responses.error("Invalid accounting_method '#{method}'. Valid: #{ACCOUNTING_METHODS.join(', ')}")
      end

      resolved = resolve_studio(studio, gradation)
      return resolved if resolved.is_a?(MCP::Tool::Response) # an error Response

      period_rows = Array(resolved.snapshot[gradation]).last(periods.to_i.clamp(1, 24)).filter_map do |entry|
        {
          label: entry['label'],
          period_starts_at: entry['period_starts_at'],
          period_ends_at: entry['period_ends_at'],
          # Pass the okrs hashes through VERBATIM (studio.rb:198-254 semantics)
          # — re-mapping would strip the target-optional / tolerance-absent
          # distinctions the grid exists to expose.
          okrs: entry.dig(method, 'okrs') || {},
        }
      rescue StandardError => e
        Rails.logger.warn("[Mcp::GetOkrGridTool] skipping period: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        nil
      end

      # Sorted union: jsonb does not preserve key insertion order, so a
      # "first-seen" ordering would be nondeterministic noise.
      okr_names = period_rows.flat_map { |row| row[:okrs].keys }.uniq.sort

      Responses.ok({
        studio: resolved.name,
        mini_name: resolved.mini_name,
        gradation: gradation,
        accounting_method: method,
        okr_names: okr_names,
        periods: period_rows,
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetOkrGridTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_okr_grid failed; the error was logged')
    end

    # Same resolution semantics as GetStudioHealthTool: exact name matches
    # take priority over mini_name-alias matches (mini_name can hold a
    # comma-separated list), and the highest-priority candidate that actually
    # has snapshot data for the gradation wins. Returns the Studio, or an
    # error Response.
    def self.resolve_studio(studio, gradation)
      all_studios = Studio.all.to_a
      key = studio.to_s.strip
      candidates = (
        all_studios.select { |s| s.name.to_s.casecmp?(key) } +
        all_studios.select { |s| s.mini_name.to_s.split(',').map(&:strip).any? { |m| m.casecmp?(key) } }
      ).uniq
      if candidates.empty?
        valid = all_studios.map { |s| "#{s.name} (#{s.mini_name})" }.sort.join(', ')
        return Responses.error("Unknown studio '#{studio}'. Valid studios: #{valid}")
      end
      match = candidates.find { |s| s.snapshot.present? && s.snapshot[gradation].present? }
      unless match
        return Responses.error("Studio '#{candidates.first.name}' has no generated snapshot for gradation '#{gradation}' yet.")
      end
      match
    end
  end
end
