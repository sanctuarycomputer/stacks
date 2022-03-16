class Stacks::Economics
  class << self
    def units_rollup(selected_studio = "garden3d")

    utilization_pass = UtilizationPass.first
    profitability_pass = ProfitabilityPass.first

    no_studio = []

    aggregated_data = utilization_pass.data.keys.reduce({}) do |acc, year|
      months = utilization_pass.data[year].keys.sort do |a, b|
        Date::MONTHNAMES.index(a.capitalize) <=> Date::MONTHNAMES.index(b.capitalize)
      end

      months.each do |month|
        actuals = profitability_pass.data["garden3d"][year][month]
        next if !actuals

        label = "#{month.capitalize}, #{year}"
        acc[label] = {}
        acc[label]["cogs"] = (
          actuals["gross_payroll"].to_f +
          actuals["gross_benefits"].to_f +
          actuals["gross_expenses"].to_f +
          actuals["gross_subcontractors"].to_f
        )

        monthly_aggregate =
          utilization_pass.data[year][month].keys.reduce({
            "garden3d": {
              "billable": [],
              "sellable": 0,
              "time_off": 0,
              "non_billable": 0
            }.with_indifferent_access
          }.with_indifferent_access) do |agg, studio|
            if studio == "None"
              no_studio = [*no_studio, *utilization_pass.data[year][month][studio].keys].uniq
              next agg
            end

            agg[studio] = agg[studio] || {
              "billable": [],
              "sellable": 0,
              "time_off": 0,
              "non_billable": 0
            }.with_indifferent_access

            utilization_pass.data[year][month][studio].values.each do |u|
              agg["garden3d"]["time_off"] += u["time_off"].to_f
              agg["garden3d"]["sellable"] += u["sellable"].to_f
              agg["garden3d"]["non_billable"] += u["non_billable"].to_f

              agg[studio]["time_off"] += u["time_off"].to_f
              agg[studio]["sellable"] += u["sellable"].to_f
              agg[studio]["non_billable"] += u["non_billable"].to_f
              u["billable"].each do |r|
                g3d_existing = agg["garden3d"]["billable"].find {|m| m["hourly_rate"] == r["hourly_rate"]}
                if g3d_existing
                  g3d_existing["allocation"] += r["allocation"]
                else
                  agg["garden3d"]["billable"] << {
                    "allocation": r["allocation"],
                    "hourly_rate": r["hourly_rate"]
                  }.with_indifferent_access
                end

                existing = agg[studio]["billable"].find {|m| m["hourly_rate"] == r["hourly_rate"]}
                if existing
                  existing["allocation"] += r["allocation"]
                else
                  agg[studio]["billable"] << {
                    "allocation": r["allocation"],
                    "hourly_rate": r["hourly_rate"]
                  }.with_indifferent_access
                end
              end
            end

            agg
          end

        acc[label]["billable"] =
          monthly_aggregate[selected_studio]["billable"].reduce(0) do |acc, u|
            acc += u["allocation"]
          end

        acc[label]["time_off"] =
          monthly_aggregate[selected_studio]["time_off"]

        acc[label]["non_billable"] =
          monthly_aggregate[selected_studio]["non_billable"]

        acc[label]["sellable"] =
          monthly_aggregate[selected_studio]["sellable"]

        acc[label]["average_hourly_rate"] =
          ((monthly_aggregate[selected_studio]["billable"].reduce(0) do |acc, u|
            acc += (u["hourly_rate"] * u["allocation"])
          end) / acc[label]["billable"])

        # TODO: Doesn't work with all Studios because COGS is not distributed equally
        if selected_studio == "garden3d"
          acc[label]["cost_per_billable_hour"] =
            acc[label]["cogs"] / acc[label]["billable"]

          acc[label]["cost_per_sellable_hour"] =
            acc[label]["cogs"] / acc[label]["sellable"]
        end
      end

      acc
    end



    end
  end
end
