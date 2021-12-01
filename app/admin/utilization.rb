ActiveAdmin.register_page "Utilization" do
  menu if: proc { current_admin_user.email == "hugh@sanctuary.computer" },
       priority: 2

  content title: "Utilization" do
    # What does a billable hour cost us, on average?
    utilization_pass = UtilizationPass.first
    profitability_pass = ProfitabilityPass.first

    #{
    #  "May, 2021": {
    #    billable_hours,
    #    cost_of_doing_business,
    #    cost_per_hour
    #  }
    #}

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
          utilization_pass.data[year][month].values.map{|u| u["billable"]}.reduce([]) do |agg, u|
            u.each do |r|
              existing = agg.find {|m| m["hourly_rate"] == r["hourly_rate"]}
              if existing
                existing["allocation"] += r["allocation"]
              else
                agg << r
              end
            end
            agg
          end

        acc[label]["billable_hours"] = monthly_aggregate
        acc[label]["total_hours_sold"] = monthly_aggregate.reduce(0) do |acc, u|
          acc += u["allocation"]
        end
        acc[label]["average_hourly_rate"] = ((monthly_aggregate.reduce(0) do |acc, u|
          acc += u["hourly_rate"]
        end) / monthly_aggregate.length)
        acc[label]["cost_per_billable_hour"] =
          acc[label]["cogs"] / acc[label]["total_hours_sold"]
      end

      acc
    end

    COLORS = Stacks::Utils::COLORS
    hourly_data = {
      labels: aggregated_data.keys,
      datasets: [{
        label: 'Internal Cost per Billable Hour',
        borderColor: COLORS[0],
        data: aggregated_data.values.map{|v| v["cost_per_billable_hour"]}
      }, {
        label: 'Average Hourly Rate Billed',
        borderColor: COLORS[1],
        data: aggregated_data.values.map{|v| v["average_hourly_rate"]}
      }]
    }

    render(partial: "utilization", locals: {
      hourly_data: hourly_data
    })
  end
end
