module Studios
  module Snapshots
    # OKR health rows for one (studio, period, datapoints) triple. Extracted
    # verbatim from Studio#okrs_for_period / #hint_for_okr so the legacy blob
    # path and the live GradationRows path share one implementation.
    class OkrRows
      def self.call(studio:, period:, datapoints:, okrs:)
        okrs.reduce({}) do |acc, okr|
          # Find all OKR periods that are associated with this studio
          okrps_for_studio = okr.okr_periods
            .select{|okrp| okrp.okr_period_studios.map(&:studio).include?(studio)}
            .sort_by{|okrp| okrp.period_starts_at}
          next acc if okrps_for_studio.empty?

          # Find the OKR period that has the most overlap with the period
          period_range = period.starts_at..period.ends_at
          okrp_candidate = okrps_for_studio.reduce({ overlap_days: nil, okrp: nil }) do |agg, okrp|
            okrp_range = okrp.period_starts_at..okrp.period_ends_at
            overlap_days = (period_range.to_a & okrp_range.to_a).count
            next { overlap_days: overlap_days, okrp: okrp } if (agg[:overlap_days].nil? || overlap_days >= agg[:overlap_days])
            agg
          end

          data = datapoints[okr.datapoint.to_sym]
          okrp = okrp_candidate[:okrp]
          acc[okr.name] = data
          next acc if okrp.nil?

          acc[okr.name] =
            okrp.health_for_value(data[:value], period.total_days)
              .merge(data)
              .merge({ hint: hint_for_okr(okr, datapoints) })

          if okrp.okr.datapoint == "profit_margin"
            target_usd =
              datapoints[:income][:value] * (acc[okrp.okr.name][:target]/100)
            surplus_usd =
              datapoints[:net_operating_income][:value]
            acc["Profit"] = {
              health: acc[okrp.okr.name][:health],
              hint: acc[okrp.okr.name][:hint],
              surplus: surplus_usd,
              value: surplus_usd,
              target: target_usd,
              unit: :usd
            }

            target_usd =
              datapoints[:income][:value] * (acc[okrp.okr.name][:target]/100)
            surplus_usd =
              datapoints[:income][:value] * (acc[okrp.okr.name][:surplus]/100)
            acc["Surplus Profit"] = {
              health: acc[okrp.okr.name][:health],
              hint: acc[okrp.okr.name][:hint],
              surplus: surplus_usd,
              value: surplus_usd,
              target: target_usd,
              unit: :usd
            }
          end
          acc
        end
      end

      def self.hint_for_okr(okr, datapoints)
        case okr.datapoint
        when "time_to_merge_pr"
          "#{datapoints[:prs_merged][:value].try(:round, 0)} PRs merged, taking #{datapoints[:time_to_merge_pr][:value].try(:round, 2)} days (average)"
        when "story_points_per_billable_week"
          "#{datapoints[:story_points][:value].try(:round, 0)} story points closed, #{((datapoints[:billable_hours][:value] || 0) / 40.0).try(:round, 2)} weeks sold"
        when "cost_per_story_point"
          "#{ActionController::Base.helpers.number_to_currency(datapoints[:cogs][:value])} spent, #{datapoints[:story_points][:value].try(:round, 0)} story points closed"
        when "sellable_hours_sold"
          "#{datapoints[:billable_hours][:value].try(:round, 0)} hrs sold of #{datapoints[:sellable_hours][:value].try(:round, 0)} sellable hrs"
        when "free_hours"
          "#{datapoints[:free_hours_count][:value].try(:round, 0)} free hrs of #{datapoints[:sellable_hours][:value].try(:round, 0)} sellable hrs"
        when "profit_margin"
          "#{ActionController::Base.helpers.number_to_currency(datapoints[:income][:value] - datapoints[:net_operating_income][:value])} spent, #{ActionController::Base.helpers.number_to_currency(datapoints[:income][:value])} earnt"
        when "income_growth"
          "#{ActionController::Base.helpers.number_to_currency(datapoints[:income][:value])} income recieved"
        when "lead_growth"
          "#{datapoints[:lead_count][:value]} leads recieved"
        else
          ""
        end
      end
    end
  end
end
