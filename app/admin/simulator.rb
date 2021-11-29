ActiveAdmin.register_page "Simulator" do
  menu if: proc { current_admin_user.email == "hugh@sanctuary.computer" },
       label: "Simulator",
       priority: 2

  content title: "Simulator" do
    pp = ProfitabilityPass.order(created_at: :desc).first
    actuals_projection =
      Stacks::Profitability.make_actuals_projections(pp)
    scenario = Stacks::ProfitShare::Scenario.new(
      actuals_projection,
      AdminUser.total_projected_psu_issued_by_eoy,
      PreProfitSharePurchase.this_year.map(&:amount).reduce(:+),
      1.5,
      1.65
    )

    # Potential Hours Sold (Based on full time periods)
    # Actual Hours Sold (check forecast)
    # Average business cost per sellable hour
    # Per-person profitability (forecast versus settled quickbooks accounts)

    total_sellable_days = AdminUser.all.reduce(0) do |acc, au|
      next acc if [
        "hugh@sanctuary.computer",
        "jake@xxix.co",
        "jacob@xxix.co",
        "nicole@sanctuary.computer",
        "isabel@sanctuary.computer"
      ].include?(au.email)

      acc + au.sellable_days_between(
        Date.today.beginning_of_year,
        Date.today.end_of_year
      )
    end

    billable_hours =
      total_sellable_days * 8
    average_cost_per_hour =
      scenario.total_cost_of_doing_business/billable_hours
    binding.pry


    render(partial: "simulator", locals: {
    })
  end
end
