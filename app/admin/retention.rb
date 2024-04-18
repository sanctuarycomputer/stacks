ActiveAdmin.register_page "Retention" do
  menu label: "Retention", parent: "Team"

  admin_users_sorted_by_tenure_in_days =
    Stacks::Team.admin_users_sorted_by_tenure_in_days

  content title: proc { I18n.t("active_admin.retention") } do
    render(partial: "show", locals: {
      average_tenure_in_days: Stacks::Team.mean_tenure_in_days(admin_users_sorted_by_tenure_in_days),
      admin_users_sorted_by_tenure_in_days: Stacks::Team.admin_users_sorted_by_tenure_in_days
    })
  end
end
