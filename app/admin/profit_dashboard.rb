ActiveAdmin.register_page "Profit Dashboard" do
  menu label: "g3d Profitability", priority: 1

  content title: proc { I18n.t("active_admin.dashboard") } do
    COLORS = Stacks::Utils::COLORS

    pp = ProfitabilityPass.order(created_at: :desc).first

    if pp.present?
      profitability_time_span = if params["profitability-time-span"].nil?
          6
        else
          if params["profitability-time-span"] == "all-time"
            "all-time"
          elsif params["profitability-time-span"].ends_with?("-months")
            params["profitability-time-span"].split("-months")[0].to_i
          else
            "all-time"
          end
        end

      studios = ["garden3d"]
      years = pp.data["garden3d"].keys
      data = { labels: [], datasets: [] }

      years.each do |year|
        months = pp.data["garden3d"][year].keys.sort do |a, b|
          Date::MONTHNAMES.index(a.capitalize) <=> Date::MONTHNAMES.index(b.capitalize)
        end

        months.each do |month|
          next if (Time.now.utc - Time.parse("#{year} #{month}").utc < 1.months)
          next if profitability_time_span.is_a?(Integer) && (Time.now.utc - Time.parse("#{year} #{month}").utc > (profitability_time_span + 1).months)

          data[:labels] << "#{month.capitalize}, #{year}"

          studios.each do |studio|
            dataset = data[:datasets].find { |d| d[:label] == studio }
            dataset = if dataset.nil?
                new_dataset = {
                  label: studio,
                  data: [],
                  borderColor: COLORS[studios.index(studio)],
                  borderWidth: 1.5,
                  fill: false,
                  hidden: ["index", "support"].include?(studio),
                }
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

      #
      all_psp = ProfitSharePass.finalized.order(created_at: :asc).all
      g3d_over_time_data = {
        labels: all_psp.map{|psp| psp.created_at.year.to_s},
        datasets: []
      }

      case params["g3d"]
      when nil, "psu"
        g3d_over_time_data[:datasets] << {
          label: 'PSU Value (USD)',
          backgroundColor: Stacks::Utils::COLORS,
          data: (all_psp.map do |psp|
            psp.make_scenario.actual_value_per_psu
          end)
        }
      when "psp"
        g3d_over_time_data[:datasets] << {
          label: 'Profit Share Pool (USD)',
          backgroundColor: Stacks::Utils::COLORS,
          data: (all_psp.map do |psp|
            psp.make_scenario.allowances[:pool_after_fica_withholding]
          end)
        }
      when "revenue"
        g3d_over_time_data[:datasets] << {
          label: 'Revenue',
          backgroundColor: Stacks::Utils::COLORS,
          data: (all_psp.map do |psp|
            psp.make_scenario.actuals[:gross_revenue]
          end)
        }
      when "margin"
        g3d_over_time_data[:datasets] << {
          label: 'Profit Margin (%)',
          backgroundColor: Stacks::Utils::COLORS,
          data: (all_psp.map do |psp|
            (psp.make_scenario.raw_efficiency * 100) - 100
          end)
        }
      else
      end

      render(partial: "profitability_chart", locals: {
        data: data,
        g3d_over_time_data: g3d_over_time_data,
        profitability_time_span: profitability_time_span,
      })
    end
  end
end
