ActiveAdmin.register_page "Admin User PSU Explorer" do
  belongs_to :admin_user

  content title: "PSU Explorer" do
    periods = Stacks::Period.for_gradation(:year).reverse
    default_year = periods.first.label
    current_year = params["year"] || default_year

    all_psu_types = ["tenure", "project_leadership", "collective_leadership"]
    default_psu_type = all_psu_types.first
    current_psu_type = params["psu_type"] || default_psu_type

    psp = current_year.downcase.start_with?("ytd") ? ProfitSharePass.this_year : ProfitSharePass.all.find{|p| p.created_at.year.to_s == current_year}

    admin_user = AdminUser.find(params["admin_user_id"])
    project_role_days = psp.project_leadership_days_by_admin_user[admin_user] || {}
    individual_total_effective_project_leadership_days = project_role_days.reduce(0) do |acc, tuple|
      role, d = tuple
      acc += d[:days] || 0
      acc
    end

    individual_total_effective_successful_project_leadership_days = project_role_days.reduce(0) do |acc, tuple|
      role, d = tuple
      acc += d[:considered_successful] ? d[:days] : 0
      acc
    end

    collective_role_days = psp.collective_leadership_days_by_admin_user[admin_user] || {}

    # Calculate this admin user's weighted days
    individual_total_weighted_collective_leadership_days = collective_role_days.values.reduce(0) do |acc, data|
      acc + (data[:days] * data[:weight])
    end

    render(partial: "admin_user_psu_explorer", locals: {
      periods: periods,
      all_years: periods.map{|p| p.label},
      current_year: current_year,
      default_year: default_year,

      all_psu_types: all_psu_types,
      current_psu_type: current_psu_type,
      default_psu_type: default_psu_type,

      admin_user: admin_user,
      psp: psp,
      project_role_days: project_role_days,
      individual_total_effective_project_leadership_days: individual_total_effective_project_leadership_days,
      individual_total_effective_successful_project_leadership_days: individual_total_effective_successful_project_leadership_days,

      collective_role_days: collective_role_days,
      individual_total_weighted_collective_leadership_days: individual_total_weighted_collective_leadership_days,
    })
  end
end