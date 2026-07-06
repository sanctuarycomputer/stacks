module Studios
  module Snapshots
    # Oracle for the live-SQL migration: diffs GradationRows output against
    # the stored legacy `studios.snapshot` blob, datapoint by datapoint.
    # Run right after a nightly generate_snapshot! so both sides read the
    # same synced data; diffs found at other times may just be staleness.
    class DiffAgainstStored
      GRADATIONS = %w[
        year month quarter
        trailing_3_months trailing_4_months trailing_6_months trailing_12_months
      ].freeze
      TOLERANCE = 0.01

      Result = Struct.new(:checked, :mismatches, keyword_init: true)

      def self.call(studio:, gradations: GRADATIONS)
        checked = 0
        mismatches = []

        gradations.each do |gradation|
          stored_rows = studio.snapshot[gradation]
          next unless stored_rows.is_a?(Array)

          live_rows = GradationRows.call(studio: studio, gradation: gradation.to_sym)
          live_by_label = live_rows.index_by { |r| r[:label] }

          stored_rows.each do |stored|
            label = stored["label"]
            live = live_by_label[label]
            if live.nil?
              mismatches << "#{gradation}/#{label}: no live row"
              next
            end

            %w[cash accrual].each do |method|
              (stored.dig(method, "datapoints") || {}).each do |key, stored_dp|
                checked += 1
                live_dp = live[method.to_sym][:datapoints][key.to_sym]
                stored_value = stored_dp.is_a?(Hash) ? stored_dp["value"] : nil
                live_value = live_dp.is_a?(Hash) ? live_dp[:value] : nil
                next if values_match?(stored_value, live_value)
                mismatches << "#{gradation}/#{label}/#{method}/#{key}: " \
                  "stored=#{stored_value.inspect} live=#{live_value.inspect}"
              end
            end
          end
        end

        Result.new(checked: checked, mismatches: mismatches)
      end

      # The blob went through ActiveSupport JSON: NaN/Infinity became nil,
      # BigDecimal became String. Compare accordingly.
      def self.values_match?(stored, live)
        live = nil if live.is_a?(Float) && !live.finite?
        return true if stored.nil? && live.nil?
        return false if stored.nil? || live.nil?
        (stored.to_f - live.to_f).abs <= TOLERANCE
      end
    end
  end
end
