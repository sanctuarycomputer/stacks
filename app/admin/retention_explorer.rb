ActiveAdmin.register_page "Retention Explorer" do
  menu label: "Retention Explorer", parent: "Team"

  admin_users_sorted_by_tenure_in_days =
    Stacks::Team.admin_users_sorted_by_tenure_in_days

  content title: proc { I18n.t("active_admin.retention_explorer") } do
    render(partial: "show", locals: {
      mean_tenure_in_days: Stacks::Team.mean_tenure_in_days(admin_users_sorted_by_tenure_in_days),
      admin_users_sorted_by_tenure_in_days: Stacks::Team.admin_users_sorted_by_tenure_in_days
    })
  end
end