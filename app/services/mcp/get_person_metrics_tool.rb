module Mcp
  class GetPersonMetricsTool < MCP::Tool
    tool_name 'get_person_metrics'
    description 'Work-shaped key metrics for one person per period, as the admin Key Metrics ' \
                'page shows them: skill-band points, billable / sellable / non-billable / ' \
                'non-sellable / time-off hours, plus derived utilization rate and sellable ' \
                'ratio. Reads the nightly garden3d utilization snapshot — no compensation, ' \
                'HR, or review content.'
    GRADATIONS = Studio::SNAPSHOT_GRADATIONS.map(&:to_s).freeze

    input_schema(
      properties: {
        email: { type: 'string', description: "The person's email. Required." },
        gradation: { type: 'string', description: "#{GRADATIONS.join(', ')} (default month)" },
        periods: { type: 'integer', description: 'How many trailing periods, default 6, max 24' },
      },
      required: ['email']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(email:, gradation: 'month', periods: 6, server_context:)
      admin = AdminUser.where('lower(email) = ?', email.to_s.strip.downcase).first
      # Deliberately do NOT enumerate valid emails here — nothing sensitive in errors.
      return Responses.error("No person found for email '#{email}'.") unless admin

      gradation = gradation.to_s
      unless GRADATIONS.include?(gradation)
        return Responses.error("Invalid gradation '#{gradation}'. Valid gradations: #{GRADATIONS.join(', ')}")
      end

      window = Stacks::Period.for_gradation(gradation.to_sym).last(periods.to_i.clamp(1, 24))
      rows = window.filter_map do |period|
        metrics = admin.key_metrics_for_period(period, gradation)
        billable = metrics.dig(:billable, :value)&.to_f
        sellable = metrics.dig(:sellable, :value)&.to_f
        non_sellable = metrics.dig(:non_sellable, :value)&.to_f
        {
          label: period.label,
          period_starts_at: period.starts_at.iso8601,
          period_ends_at: period.ends_at.iso8601,
          skill_points: metrics.dig(:skill_points, :value),
          billable: billable,
          sellable: sellable,
          non_billable: metrics.dig(:non_billable, :value)&.to_f,
          non_sellable: non_sellable,
          time_off: metrics.dig(:time_off, :value)&.to_f,
          # Derived exactly like the admin page (rescue -> 0 semantics):
          utilization_rate: pct_ratio(billable, sellable),
          sellable_ratio: pct_ratio(sellable, sellable && non_sellable ? sellable + non_sellable : nil),
        }
      rescue StandardError => e2
        Rails.logger.warn("[Mcp::GetPersonMetricsTool] skipping period #{period.label}: #{e2.class}: #{e2.message}")
        Sentry.capture_exception(e2) if defined?(Sentry)
        nil
      end

      Responses.ok({
        person: admin.email,
        gradation: gradation,
        periods: rows,
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::GetPersonMetricsTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('get_person_metrics failed; the error was logged')
    end

    # Mirrors admin_user_key_metrics.rb's `rescue 0` guards: missing data or a
    # zero denominator yields 0, never nil/Infinity/exception.
    def self.pct_ratio(numerator, denominator)
      return 0.0 if numerator.nil? || denominator.nil?
      value = (numerator / denominator) * 100
      return 0.0 unless value.finite?
      value.round(2)
    end
  end
end
