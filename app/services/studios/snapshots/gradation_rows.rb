module Studios
  module Snapshots
    # Live replacement for `studios.snapshot[gradation]`: computes rows
    # shape-identical to the blob from span-wide grouped queries folded into
    # periods in Ruby. Every period Stacks::Period builds is month-aligned,
    # and each datapoint is additive over months or a ratio of additive
    # sums, so the monthly grain reproduces every gradation exactly.
    #
    # HARD RULES:
    # - Never trigger a network call. Reads only locally-synced tables.
    # - Replicate Studio#key_datapoints_for_period bug-for-bug (NaN/Infinity
    #   from .to_f division, midnight-cast work_completed_at bounds, ...).
    #   The DiffAgainstStored oracle is the referee — "more correct" is a
    #   diff, and a diff is a bug here.
    class GradationRows
      def self.call(studio:, gradation:, periods: nil)
        new(studio, gradation, periods).call
      end

      def initialize(studio, gradation, periods)
        @studio = studio
        @gradation = gradation
        @periods = periods || Stacks::Period.for_gradation(gradation)
      end

      def call
        return [] if @periods.empty?
        preload_span_data!
        warn_on_pnl_gaps!
        @periods.each_with_index.map do |period, i|
          prev_period = i.zero? ? nil : @periods[i - 1]
          row_for(period, prev_period)
        end
      end

      private

      def preload_span_data!
        @from = @periods.map(&:starts_at).min
        @through = @periods.map(&:ends_at).max
        @pnl_by_month = PnlByMonth.call(studio: @studio, from: @from, through: @through)
        @utilization_by_month = UtilizationByMonth.call(studio: @studio, from: @from, through: @through)
        @lead_rows = NotionLead.for_studio(@studio).to_a
        @projects_by_period = @studio.project_trackers_with_recorded_time_by_periods(@periods)
        @completed_projects = ProjectTracker
          .includes(project_capsule: { project_satisfaction_survey: :project_satisfaction_survey_responses })
          .where(work_completed_at: @from..@through)
          .to_a
        @closed_surveys = @studio.surveys.where.not(closed_at: nil).order(closed_at: :desc).to_a
        @all_okrs = Okr.includes({ okr_periods: { okr_period_studios: :studio } }).all.to_a
      end

      # Warn per accounting method: a month present in cash but absent from
      # accrual (or vice-versa) is still a gap, so each method is checked
      # against the full expected month set independently. One warn per
      # gradation, naming the short method(s) and the months each lacks.
      def warn_on_pnl_gaps!
        expected = months_in_range(@from, @through)
        gaps = %w[cash accrual].filter_map do |method|
          missing = expected - @pnl_by_month[method].keys
          next if missing.empty?
          "#{method}: #{missing.map(&:iso8601).join(', ')}"
        end
        return if gaps.empty?
        Rails.logger.warn(
          "[Studios::Snapshots::GradationRows] studio=#{@studio.mini_name} " \
          "gradation=#{@gradation} missing P&L months by method — #{gaps.join('; ')}"
        )
      end

      def months_in_range(from, through)
        months = []
        m = from.beginning_of_month
        while m <= through
          months << m
          m = m.advance(months: 1)
        end
        months
      end

      def row_for(period, prev_period)
        row = {
          label: period.label,
          period_starts_at: period.starts_at.strftime("%m/%d/%Y"),
          period_ends_at: period.ends_at.strftime("%m/%d/%Y"),
          cash: {},
          accrual: {},
          utilization: utilization_breakdown(period),
        }
        %w[cash accrual].each do |method|
          datapoints = datapoints_for(period, prev_period, method)
          row[method.to_sym][:datapoints] = datapoints
          row[method.to_sym][:okrs] = OkrRows.call(
            studio: @studio, period: period, datapoints: datapoints, okrs: @all_okrs
          )
        end
        row
      end

      # ------------------------------------------------------- utilization

      # Per-person period totals folded from monthly rows. Mirrors the BLOB
      # path (Studio#utilization_by_period_gradation, studio.rb:51-76), which
      # has NO date gate — utilization is purely a function of which monthly
      # FPUR rows exist. sync_utilization_reports! generates rows back to
      # 2020-01-01, so pre-2021-06 periods DO carry numeric utilization in the
      # stored blob; gating on has_utilization_data? here would nil them and
      # guarantee an oracle mismatch. UtilizationByMonth returns only months
      # that have rows, so a period with no rows still folds to {} → nil v →
      # nil datapoints, matching the blob's empty-report behavior.
      def person_utilization_for(period)
        @person_utilization ||= {}
        @person_utilization[period] ||=
          months_in_range(period.starts_at, period.ends_at).reduce({}) do |acc, month|
            (@utilization_by_month[month] || {}).each do |fp, data|
              acc[fp] = acc[fp].nil? ? data : merge_utilization(acc[fp], data)
            end
            acc
          end
      end

      # Mirrors the merge inside legacy merged_utilization_data.
      def merge_utilization(a, b)
        a.merge(b) do |_k, old, new|
          old.is_a?(Hash) ? old.merge(new) { |_kk, o, n| o + n } : old + new
        end
      end

      def merged_utilization_for(period)
        person_utilization_for(period).values.reduce(nil) do |acc, data|
          acc.nil? ? data : merge_utilization(acc, data)
        end
      end

      def utilization_breakdown(period)
        person_utilization_for(period).transform_keys do |fp|
          fp.email.blank? ? "#{fp.first_name} #{fp.last_name}" : fp.email
        end
      end

      # -------------------------------------------------------------- P&L

      def pnl_totals_for(period, accounting_method)
        totals = { income: 0.0, cost_of_goods_sold: 0.0, expenses: 0.0, net_operating_income: 0.0 }
        months_in_range(period.starts_at, period.ends_at).each do |month|
          m = @pnl_by_month.dig(accounting_method, month)
          next if m.nil?
          totals.each_key { |k| totals[k] += m[k] }
        end
        totals
      end

      # ------------------------------------------------------- datapoints

      # Replicates Studio#key_datapoints_for_period exactly.
      def datapoints_for(period, prev_period, accounting_method)
        profit_and_loss = pnl_totals_for(period, accounting_method)
        prev_profit_and_loss = pnl_totals_for(prev_period, accounting_method) if prev_period.present?
        v = merged_utilization_for(period)
        cost_of_doing_business = profit_and_loss[:income] - profit_and_loss[:net_operating_income]

        leads_recieved = leads_received_in(period)
        prev_leads_recieved = prev_period.present? ? leads_received_in(prev_period) : []
        all_proposals = proposals_settled_in(period)
        all_projects = @projects_by_period.fetch(period, [])

        completed_projects_in_period = completed_projects_in(period).select do |pt|
          pt.capsule_complete? &&
            pt.project_capsule.project_satisfaction_survey.present? &&
            pt.project_capsule.project_satisfaction_survey.closed?
        end
        project_satisfaction_score = nil
        if completed_projects_in_period.any?
          scores = completed_projects_in_period.map { |pt| pt.project_capsule.project_satisfaction_survey.results[:overall] }
          project_satisfaction_score = (scores.reduce(&:+) / scores.count).round(1)
        end

        latest_survey_closed = @closed_surveys.find do |s|
          s.closed_at.beginning_of_year <= period.starts_at
        end

        data = {
          income: {
            value: profit_and_loss[:income],
            unit: :usd,
            growth: prev_profit_and_loss ? ((profit_and_loss[:income].to_f / prev_profit_and_loss[:income].to_f) * 100) - 100 : nil
          },
          income_growth: {
            value: prev_profit_and_loss ? ((profit_and_loss[:income].to_f / prev_profit_and_loss[:income].to_f) * 100) - 100 : nil,
            unit: :percentage
          },
          cost_of_goods_sold: {
            value: profit_and_loss[:cost_of_goods_sold],
            unit: :usd
          },
          expenses: {
            value: profit_and_loss[:expenses],
            unit: :usd
          },
          net_operating_income: {
            value: profit_and_loss[:net_operating_income],
            unit: :usd
          },
          profit_margin: {
            value: profit_and_loss[:income] ? (profit_and_loss[:net_operating_income] / profit_and_loss[:income]) * 100 : 0,
            unit: :percentage
          },
          lead_count: {
            value: leads_recieved.length,
            unit: :count,
            growth: prev_period ? ((leads_recieved.length.to_f / prev_leads_recieved.length.to_f) * 100) - 100 : nil
          },
          lead_growth: {
            value: prev_period ? ((leads_recieved.length.to_f / prev_leads_recieved.length.to_f) * 100) - 100 : nil,
            unit: :percentage
          },
          total_projects: {
            value: all_projects.count,
            unit: :count,
            extras: {
              project_tracker_ids: all_projects.map(&:id)
            }
          },
          successful_projects: {
            value: ((all_projects.map(&:considered_successful?).count { |x| !!x } / all_projects.count.to_f) * 100),
            unit: :percentage,
            extras: {
              project_tracker_ids: all_projects.map(&:id)
            }
          },
          successful_proposals: {
            value: ((all_proposals.map { |l| l.won_at.present? }.count { |x| !!x } / all_proposals.count.to_f) * 100),
            unit: :percentage,
            extras: {
              notion_page_ids: all_proposals.map(&:notion_page_id)
            }
          },
          project_satisfaction: {
            value: project_satisfaction_score,
            unit: :count,
            extras: {
              project_tracker_ids: completed_projects_in_period.map(&:id)
            }
          },
          workplace_satisfaction: {
            value: latest_survey_closed.try(:results).try(:dig, :overall),
            unit: :count
          }
        }

        data[:free_hours] = { unit: :percentage, value: nil }
        data[:free_hours_count] = { unit: :count, value: nil }
        unless v.nil?
          free_hours_given = v[:billable]["0.0"] || 0
          data[:free_hours][:value] = v[:sellable] == 0 ? 0 : ((free_hours_given / v[:sellable]) * 100)
          data[:free_hours_count][:value] = free_hours_given
        end

        data[:sellable_hours] = { unit: :hours, value: nil }
        unless v.nil?
          data[:sellable_hours][:value] = v[:sellable]
        end

        data[:non_sellable_hours] = { unit: :hours, value: nil }
        unless v.nil?
          data[:non_sellable_hours][:value] = v[:non_sellable]
        end

        data[:billable_hours] = { unit: :hours, value: nil }
        unless v.nil?
          total_billable = v[:billable].values.reduce(&:+) || 0
          data[:billable_hours][:value] = total_billable
        end

        data[:non_billable_hours] = { unit: :hours, value: nil }
        unless v.nil?
          data[:non_billable_hours][:value] = v[:non_billable]
        end

        data[:time_off] = { unit: :hours, value: nil }
        unless v.nil?
          data[:time_off][:value] = v[:time_off]
        end

        data[:sellable_hours_sold] = { unit: :percentage, value: nil }
        unless v.nil?
          total_billable = v[:billable].values.reduce(&:+) || 0
          begin
            data[:sellable_hours_sold][:value] = (total_billable / v[:sellable]) * 100
          rescue ZeroDivisionError
            data[:sellable_hours_sold][:value] = 0
          end
        end

        data[:sellable_hours_ratio] = { unit: :percentage, value: nil }
        unless v.nil?
          begin
            data[:sellable_hours_ratio][:value] =
              (v[:sellable] / (v[:sellable] + v[:non_sellable])) * 100
          rescue ZeroDivisionError
            data[:sellable_hours_ratio][:value] = 0
          end
        end

        data[:average_hourly_rate] = { unit: :usd, value: nil }
        unless v.nil?
          data[:average_hourly_rate][:value] =
            Stacks::Utils.weighted_average(v[:billable].map { |k, hours| [k.to_f, hours] })
        end

        data[:actual_cost_per_hour_sold] = { unit: :usd, value: nil }
        unless v.nil?
          total_billable = v[:billable].values.reduce(&:+) || 0
          data[:actual_cost_per_hour_sold][:value] = total_billable > 0 ? (cost_of_doing_business / total_billable) : 0
        end

        data
      end

      # ------------------------------------------------------------ leads

      def leads_received_in(period)
        @lead_rows.select { |l| l.received_at && period.include?(l.received_at) }
      end

      def proposals_settled_in(period)
        @lead_rows.select { |l| l.settled_at && l.proposal_sent_at && period.include?(l.settled_at) }
      end

      # --------------------------------------------------------- projects

      # Legacy queried `work_completed_at: period.starts_at..period.ends_at`
      # — a Date range against a datetime column casts both bounds to
      # midnight, so completions later in the day on ends_at fall out.
      # Preserve that quirk.
      def completed_projects_in(period)
        start_t = period.starts_at.in_time_zone
        end_t = period.ends_at.in_time_zone
        @completed_projects.select do |pt|
          pt.work_completed_at >= start_t && pt.work_completed_at <= end_t
        end
      end
    end
  end
end
