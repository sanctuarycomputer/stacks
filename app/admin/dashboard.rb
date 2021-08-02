ActiveAdmin.register_page "Dashboard" do
  content title: proc { I18n.t("active_admin.dashboard") } do
    pp = ProfitabilityPass.first
    if pp.present?
      studios = pp.data.keys
      years = pp.data["garden3d"].keys
      data = { labels: [], datasets: [] }

      years.each do |year|
        months = pp.data["garden3d"][year].keys.sort do |a, b|
          Date::MONTHNAMES.index(a.capitalize) <=> Date::MONTHNAMES.index(b.capitalize)
        end

        months.each do |month|
          data[:labels] << "#{month.capitalize}, #{year}"

          studios.each do |studio|
            dataset = data[:datasets].find { |d| d[:label] == studio }
            dataset = if dataset.nil?
                new_dataset = { label: studio, data: [] }
                data[:datasets] << new_dataset
                new_dataset
              else
                dataset
              end

            raw_data = pp.data[studio][year][month]
            net_income = raw_data["gross_revenue"].to_f - raw_data["gross_payroll"].to_f - raw_data["gross_benefits"].to_f - raw_data["gross_expenses"].to_f - raw_data["gross_subcontractors"].to_f

            profit_margin = if net_income != 0 && raw_data["gross_revenue"].to_f > 0
                net_income / raw_data["gross_revenue"].to_f
              else
                0
              end
            dataset[:data] << profit_margin * 100
          end
        end
      end

      render(partial: "profitability_chart", locals: { data: data })
    end
  end
end
