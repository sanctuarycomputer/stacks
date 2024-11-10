ActiveAdmin.register_page "Admin User Roles" do
  belongs_to :admin_user

  content title: "Roles" do
    admin_user = AdminUser.includes(
      technical_lead_periods: [project_tracker: [:forecast_assignments]],
      creative_lead_periods: [project_tracker: [:forecast_assignments]],
      project_lead_periods: [project_tracker: [:forecast_assignments]]
    ).find(params["admin_user_id"])

    total_role_days_by_period = AdminUser.all.includes(
      technical_lead_periods: [project_tracker: [:forecast_assignments]],
      creative_lead_periods: [project_tracker: [:forecast_assignments]],
      project_lead_periods: [project_tracker: [:forecast_assignments]]
    ).reduce({}) do |acc, a|
      a.roles_by_year.each do |period, roles|
        acc[period.label] = acc[period.label] || 0
        acc[period.label] += (roles.map do |p|
          p.effective_days_in_role_during_range(period.starts_at, period.ends_at)
        end.reduce(&:+) || 1)
      end
      acc
    end

    render(partial: "admin_user_roles", locals: {
      admin_user: admin_user,
      total_role_days_by_period: total_role_days_by_period
    })
  end
end
