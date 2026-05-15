module Stacks
  # Diagnostic for the Runn ↔ Stacks LTV mismatch that
  # `ProjectTrackerForecastToRunnSyncTask#sync!` raises (Stacks::Errors::Base
  # "Failed Runn sync ... Runn Revenue: X, Project Tracker LTV: Y"). The
  # sync builds Runn actuals FROM forecast assignments, so the two totals
  # should reconcile; when they don't, the gap is almost always one of:
  #
  #   - Integer truncation in allocation_during_range_in_seconds / 3600
  #     (the Stacks side rounds down hours, the Runn side keeps minute
  #     fractions).
  #   - A Runn role's `standardRate` drifted from its corresponding
  #     Forecast project's `hourly_rate` (sync creates roles, doesn't
  #     update them).
  #   - Forecast assignments that collapse into a shared Runn actual when
  #     two FPs share the same (rate, person, date) but contribute
  #     separately to Stacks LTV.
  #
  # The diagnostic computes both totals locally without writing anything,
  # caches Runn responses to tmp/ for fast iteration, and emits a per-FP
  # / per-role breakdown so the offending bucket pops out.
  class RunnSyncDiagnostic
    Result = Struct.new(
      :project_tracker,
      :stacks_ltv,
      :runn_revenue,
      :diff,
      :stacks_breakdown,
      :runn_breakdown,
      :unmatched_runn_actuals,
      keyword_init: true,
    )

    def initialize(project_tracker, runn_actuals: nil, runn_roles: nil)
      @pt = project_tracker
      @runn_actuals = runn_actuals
      @runn_roles = runn_roles
    end

    def call
      load_runn_data!
      Result.new(
        project_tracker: @pt,
        stacks_ltv: stacks_ltv,
        runn_revenue: runn_revenue,
        diff: stacks_ltv - runn_revenue,
        stacks_breakdown: stacks_breakdown,
        runn_breakdown: runn_breakdown,
        unmatched_runn_actuals: unmatched_runn_actuals,
      )
    end

    def report!(io: $stdout)
      r = call
      io.puts "=== ProjectTracker '#{r.project_tracker.name}' (id=#{r.project_tracker.id}) ==="
      io.puts "  range:              #{r.project_tracker.start_date}..#{r.project_tracker.end_date}"
      io.puts "  Stacks LTV:         $#{format("%.2f", r.stacks_ltv)}"
      io.puts "  Runn Revenue:       $#{format("%.2f", r.runn_revenue)}"
      io.puts "  Diff (Stacks-Runn): $#{format("%.2f", r.diff)}"
      io.puts ""
      io.puts "Stacks breakdown by ForecastProject:"
      r.stacks_breakdown.each do |b|
        io.puts "  fp=#{b[:forecast_project_id].to_s.ljust(10)} rate=$#{format("%.2f", b[:hourly_rate]).rjust(8)}  hours=#{format("%.4f", b[:hours]).rjust(11)}  value=$#{format("%.2f", b[:value]).rjust(12)}  assignments=#{b[:assignments]}  name=#{b[:name].inspect}"
      end
      io.puts ""
      io.puts "Runn breakdown by role:"
      r.runn_breakdown.each do |b|
        hours = b[:billable_minutes] / 60.0
        rate = b[:standard_rate]
        io.puts "  role=#{b[:role_id].to_s.ljust(10)} rate=$#{format("%.2f", rate).rjust(8)}  hours=#{format("%.4f", hours).rjust(11)}  value=$#{format("%.2f", b[:value]).rjust(12)}  actuals=#{b[:actuals_count]}  name=#{b[:role_name].inspect}"
      end
      if r.unmatched_runn_actuals.any?
        io.puts ""
        io.puts "WARNING: #{r.unmatched_runn_actuals.size} Runn actuals reference roleIds not in Runn roles list (skipped):"
        r.unmatched_runn_actuals.first(10).each do |ra|
          io.puts "  date=#{ra["date"]} roleId=#{ra["roleId"]} personId=#{ra["personId"]} billableMinutes=#{ra["billableMinutes"]}"
        end
      end
      r
    end

    private

    def load_runn_data!
      return if @runn_actuals && @runn_roles
      runn = Stacks::Runn.new
      @runn_actuals ||= runn.get_actuals_for_project(@pt.runn_project.runn_id)
      @runn_roles ||= runn.get_roles
    end

    def stacks_ltv
      @_stacks_ltv ||= @pt.lifetime_value
    end

    def stacks_breakdown
      @_stacks_breakdown ||= @pt.forecast_projects.map do |fp|
        {
          forecast_project_id: fp.forecast_id,
          name: fp.name,
          hourly_rate: fp.hourly_rate.to_f,
          assignments: fp.forecast_assignments.size,
          hours: fp.total_hours_during_range(@pt.start_date, @pt.end_date).to_f,
          value: fp.total_value_during_range(@pt.start_date, @pt.end_date).to_f,
        }
      end
    end

    def runn_revenue
      @_runn_revenue ||= @runn_actuals.reduce(0.0) do |acc, ra|
        role = role_for(ra)
        next acc if role.nil?
        acc + role["standardRate"] * (ra["billableMinutes"] / 60.0)
      end
    end

    def runn_breakdown
      @_runn_breakdown ||= @runn_actuals
        .group_by { |ra| ra["roleId"] }
        .map do |role_id, actuals|
          role = @runn_roles.find { |r| r["id"] == role_id }
          standard_rate = role&.dig("standardRate") || 0.0
          billable_minutes = actuals.sum { |ra| ra["billableMinutes"].to_f }
          {
            role_id: role_id,
            role_name: role&.dig("name") || "(unknown)",
            standard_rate: standard_rate,
            billable_minutes: billable_minutes,
            value: standard_rate * (billable_minutes / 60.0),
            actuals_count: actuals.size,
          }
        end.sort_by { |b| -b[:value] }
    end

    def unmatched_runn_actuals
      @_unmatched ||= @runn_actuals.reject { |ra| role_for(ra) }
    end

    def role_for(actual)
      @runn_roles.find { |r| r["id"] == actual["roleId"] }
    end
  end
end
