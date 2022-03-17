ActiveAdmin.register Studio do
  config.filters = false
  config.paginate = false
  actions :index, :show

  index download_links: false do
    column :name
    actions
  end

  show do
    COLORS = Stacks::Utils::COLORS

    pp = ProfitabilityPass.order(created_at: :desc).first
    studio_data = pp.data[resource.mini_name]

    studio_yearly_data = studio_data.keys.reduce({
      labels: [],
      datasets: []
    }) do |acc, year|
      acc[:labels] << year

      dataset = {
        gross_payroll: studio_data[year].values.map{|v| v["gross_payroll"].to_f}.reduce(:+),
        gross_revenue: studio_data[year].values.map{|v| v["gross_revenue"].to_f}.reduce(:+),
        gross_benefits: studio_data[year].values.map{|v| v["gross_benefits"].to_f}.reduce(:+),
        gross_expenses: studio_data[year].values.map{|v| v["gross_expenses"].to_f}.reduce(:+),
        gross_subcontractors: studio_data[year].values.map{|v| v["gross_subcontractors"].to_f}.reduce(:+),
      }
      dataset[:net_revenue] = (
        dataset[:gross_revenue] - (
          dataset[:gross_payroll] +
          dataset[:gross_benefits] +
          dataset[:gross_expenses] +
          dataset[:gross_subcontractors]
        )
      )
      dataset[:margin] = (dataset[:net_revenue] / dataset[:gross_revenue]) * 100

      # COGS
      [
        "gross_payroll",
        "gross_benefits",
        "gross_expenses",
        "gross_subcontractors",
      ].each_with_index do |dp, idx|
        ds = acc[:datasets].find{|d| d[:label] == dp.humanize}
        unless ds.present?
          ds = { label: dp.humanize, data: [], stack: 'cogs', backgroundColor: COLORS[idx + 1], order: 1 }
          acc[:datasets] << ds
        end
        ds[:data] << dataset[dp.to_sym]
      end

      # Gross Revenue
      ds = acc[:datasets].find{|d| d[:label] == "Gross revenue"}
      unless ds.present?
        ds = { label: "Gross revenue", data: [], backgroundColor: COLORS[0], order: 1 }
        acc[:datasets] << ds
      end
      ds[:data] << dataset[:gross_revenue]

      # Margin
      ds = acc[:datasets].find{|d| d[:label] == "Profit margin"}
      unless ds.present?
        ds = {
          label: "Profit margin",
          data: [],
          yAxisID: 'y1',
          type: 'line',
        }
        acc[:datasets] << ds
      end
      ds[:data] << dataset[:margin]

      acc
    end

    studio_monthly_data = studio_data.keys.reduce({
      labels: [],
      datasets: []
    }) do |acc, year|
      months = studio_data[year].keys.sort do |a, b|
        Date::MONTHNAMES.index(a.capitalize) <=> Date::MONTHNAMES.index(b.capitalize)
      end

      months.each do |month|
        acc[:labels] << "#{month.capitalize}, #{year}"
        dataset = studio_data[year][month].clone.symbolize_keys
        dataset.update(dataset) {|k, v| v.to_f}
        dataset[:net_revenue] = (
          dataset[:gross_revenue] - (
            dataset[:gross_payroll] +
            dataset[:gross_benefits] +
            dataset[:gross_expenses] +
            dataset[:gross_subcontractors]
          )
        )
        dataset[:margin] = (dataset[:net_revenue] / dataset[:gross_revenue]) * 100

        [
          "gross_payroll",
          "gross_benefits",
          "gross_expenses",
          "gross_subcontractors",
        ].each_with_index do |dp, idx|
          ds = acc[:datasets].find{|d| d[:label] == dp.humanize}
          unless ds.present?
            ds = { label: dp.humanize, data: [], stack: 'cogs', backgroundColor: COLORS[idx + 1], order: 1 }
            acc[:datasets] << ds
          end
          ds[:data] << dataset[dp.to_sym]
        end

        # Gross Revenue
        ds = acc[:datasets].find{|d| d[:label] == "Gross revenue"}
        unless ds.present?
          ds = { label: "Gross revenue", data: [], backgroundColor: COLORS[0], order: 1 }
          acc[:datasets] << ds
        end
        ds[:data] << dataset[:gross_revenue]

        # Margin
        ds = acc[:datasets].find{|d| d[:label] == "Profit margin"}
        unless ds.present?
          ds = {
            label: "Profit margin",
            data: [],
            yAxisID: 'y1',
            type: 'line',
          }
          acc[:datasets] << ds
        end
        ds[:data] << dataset[:margin]

      end

      acc
    end

    # Start Utilization
    periods = []
    graduated_by = "month"
    case graduated_by
    when nil
    when "month"
      time = Stacks::System.singleton_class::UTILIZATION_START_AT
      while time < Date.today.last_month.end_of_month
        periods << {
          label: time.to_s,
          starts_at: time.beginning_of_month,
          ends_at: time.end_of_month
        }
        time = time.advance(months: 1)
      end
    end

    studio_people =
      ForecastPerson.includes(:admin_user).all.select do |fp|
        fp.studio == resource
      end.reduce({}) do |acc, fp|
        acc[fp] = periods.reduce({}) do |agr, period|
          agr[period[:label]] = fp.utilization_during_range(
            period[:starts_at],
            period[:ends_at]
          )

          if fp.admin_user.present?
            working_days = fp.admin_user.working_days_between(
              period[:starts_at],
              period[:ends_at],
            ).count
            sellable_hours = (working_days * fp.admin_user.expected_utilization * 8)
            non_sellable_hours = (working_days * 8) - sellable_hours
            agr[period[:label]] = agr[period[:label]].merge({
              sellable: sellable_hours,
              non_sellable: non_sellable_hours
            })
          end

          agr
        end
        acc
      end

    # TODO: Should we be including Time Off for 4-day workers
    # in the Time Off count?
    aggregated_data =
      studio_people.values.reduce({}) do |acc, periods|
        periods.each do |label, data|
          next acc[label] = data unless acc[label].present?
          acc[label] = acc[label].merge(data) do |k, old, new|
            old.is_a?(Hash) ? old.merge(new) {|k, o, n| o+n} : old + new
          end
        end
        acc
      end

    studio_utilization_data = {
      labels: aggregated_data.keys,
      datasets: []
    }

    studio_utilization_data[:datasets].concat([{
      label: 'Utilization Rate (%)',
      borderColor: COLORS[4],
      data: (aggregated_data.values.map do |v|
        total_billable = v[:billable].values.reduce(&:+)
        (total_billable / v[:sellable]) * 100
      end),
      yAxisID: 'y2',
    }, {
      label: 'Actual Hours Sold',
      backgroundColor: COLORS[8],
      data: (aggregated_data.values.map do |v|
        v[:billable].values.reduce(&:+)
      end),
      yAxisID: 'y1',
      type: 'bar',
      stack: 'Stack 0',
    }, {
      label: 'Non Billable',
      backgroundColor: COLORS[6],
      data: aggregated_data.values.map{|v| v[:non_billable]},
      yAxisID: 'y1',
      type: 'bar',
      stack: 'Stack 0',
    }, {
      label: 'Time Off',
      backgroundColor: COLORS[9],
      data: aggregated_data.values.map{|v| v[:time_off]},
      yAxisID: 'y1',
      type: 'bar',
      stack: 'Stack 0',
    }, {
      label: 'Sellable Hours',
      backgroundColor: COLORS[2],
      data: aggregated_data.values.map{|v| v[:sellable]},
      yAxisID: 'y1',
      type: 'bar',
      stack: 'Stack 1',
    }, {
      label: 'Non Sellable Hours',
      backgroundColor: COLORS[5],
      data: aggregated_data.values.map{|v| v[:non_sellable]},
      yAxisID: 'y1',
      type: 'bar',
      stack: 'Stack 1',
    }])

    render(partial: "show", locals: {
      studio_yearly_data: studio_yearly_data,
      studio_monthly_data: studio_monthly_data,
      studio_utilization_data: studio_utilization_data,
      studio_people: studio_people
    })
  end
end
