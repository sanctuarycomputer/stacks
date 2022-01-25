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

    render(partial: "show", locals: {
      studio_yearly_data: studio_yearly_data,
      studio_monthly_data: studio_monthly_data
    })
  end
end
