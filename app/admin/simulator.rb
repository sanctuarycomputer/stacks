ActiveAdmin.register_page "Simulator" do
  menu if: proc { current_admin_user.is_admin? },
       label: "Simulator"

  content title: "Simulator" do
    simulator_data = {
      labels: [],
      datasets: []
    }

    opt_ins = [0.2, 0.5, 0.9]
    rates = [150, 160, 170, 180]

    time_start = DateTime.parse("1st June 2021")
    time_end = 0.seconds.ago - 1.month
    time = time_start

    months = []
    while time < time_end
      date = time.to_date
      simulator_data[:labels] << "#{Date::MONTHNAMES[date.month]}, #{date.year}"
      months << date
      time = time.advance(months: 1)
    end

    # Actuals
    pp = ProfitabilityPass.order(created_at: :desc).first
    dataset = months.map do |month|
      raw_data = pp.data["garden3d"][month.year.to_s][Date::MONTHNAMES[month.month].downcase]
      net_income = raw_data["gross_revenue"].to_f - raw_data["gross_payroll"].to_f - raw_data["gross_benefits"].to_f - raw_data["gross_expenses"].to_f - raw_data["gross_subcontractors"].to_f
      profit_margin = if net_income != 0 && raw_data["gross_revenue"].to_f > 0
          net_income / raw_data["gross_revenue"].to_f
        else
          0
        end
      profit_margin * 100
    end

    simulator_data[:datasets] << {
      label: "Actual",
      borderColor: "#39FF14",
      borderWidth: 3,
      data: dataset
    }

    # Scenarios
    opt_ins.each do |opt_in|
      rates.each do |rate|
        dataset = months.map do |month|
          Stacks::Simulator.do(month, opt_in, rate)[:margin_in_scenario] * 100
        end
        simulator_data[:datasets] << {
          label: "#{opt_in * 100}% Opt-In, $#{rate} p/hr",
          borderColor: Stacks::Utils::COLORS[rates.index(rate)],
          data: dataset
        }
      end
    end

    render(partial: "simulator", locals: {
      simulator_data: simulator_data
    })
  end
end
