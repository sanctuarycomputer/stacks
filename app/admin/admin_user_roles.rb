ActiveAdmin.register_page "Admin User Roles" do
  belongs_to :admin_user

  content title: "Roles" do
    periods = Stacks::Period.for_gradation(:year).reverse
    default_year = periods.first.label
    current_year = params["year"] || default_year

    psp = current_year.downcase.start_with?("ytd") ? ProfitSharePass.this_year : ProfitSharePass.all.find{|p| p.created_at.year.to_s == current_year}

    # TODO: What if a very old user
    admin_user = AdminUser.find(params["admin_user_id"])
    _, project_role_days = psp.project_leadership_days_by_admin_user.find do |a, data|
      a == admin_user
    end
    project_role_days = {} if project_role_days.nil?

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

    render(partial: "admin_user_roles", locals: {
      periods: periods,
      all_years: periods.map{|p| p.label},
      current_year: current_year,
      default_year: default_year,

      admin_user: admin_user,
      psp: psp,
      individual_total_effective_project_leadership_days: individual_total_effective_project_leadership_days,
      individual_total_effective_successful_project_leadership_days: individual_total_effective_successful_project_leadership_days,
    })
  end
end
