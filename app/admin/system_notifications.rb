ActiveAdmin.register_page "System Notifications" do
  menu parent: "Notifications"

  content do
    render(partial: "notifications", locals: {
      notifications: Stacks::Notifications.notifications,
    })
  end
end
