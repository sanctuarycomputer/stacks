ActiveAdmin.register_page "Notifications" do
  menu parent: "Dashboard"

  content do
    render(partial: "notifications", locals: {
      notifications: Stacks::Notifications.notifications,
    })
  end
end
