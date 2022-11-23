ActiveAdmin.register System do
  menu if: -> { current_admin_user.is_admin? },
        priority: 0,
        label: -> {
          div("#{System.instance.notifications.unread.count}", class: "notifier")
          "System"
        },
        url: -> { url_for [:admin, :system] }

  actions :show, :edit, :update
  permit_params settings: [System.storext_definitions.keys]

  action_item :trigger_forecast_sync, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to "Sync Forecast", trigger_forecast_sync_admin_system_path(resource), method: :post
  end

  action_item :trigger_qbo_sync, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to "Sync QBO", trigger_qbo_sync_admin_system_path(resource), method: :post
  end

  member_action :mark_as_read, method: :post do
    System.instance.notifications.find(params["notification_id"]).mark_as_read!
    redirect_to admin_system_path, notice: "Snoozed! If it's still a problem in 1 week's time, a new notification will surface."
  end

  member_action :mark_as_unread, method: :post do
    System.instance.notifications.find(params["notification_id"]).mark_as_unread!
    redirect_to admin_system_path, notice: "Unsnoozed!"
  end

  member_action :trigger_forecast_sync, method: :post do
    Stacks::Forecast.new.sync_all!
    redirect_to admin_system_path, notice: "Forecast synced!"
  end

  member_action :trigger_qbo_sync, method: :post do
    Stacks::Quickbooks.sync_all!
    redirect_to admin_system_path, notice: "Quickbooks synced!"
  end

  form do |f|
    f.inputs for: :settings do |s|
      s.input :default_hourly_rate,
        as: :number,
        input_html: { value: resource.default_hourly_rate }
      s.input :tentative_assignment_label,
        as: :string,
        input_html: { value: resource.tentative_assignment_label }
      s.input :expected_skill_tree_cadence_days,
        as: :number,
        input_html: { value: resource.expected_skill_tree_cadence_days }
    end

    f.actions do
      action :submit
      cancel_link [:admin, :system]
    end
  end

  controller do
    defaults singleton: true
    def resource
      @resource ||= System.instance
    end
  end

  show do
    notification_view_modes = ["unread", "read"]
    default_notification_view_mode = "unread"
    current_notification_view_mode =
      params["notification_view"] || default_notification_view_mode
    current_notification_view_mode =
      default_notification_view_mode unless notification_view_modes.include?(current_notification_view_mode)

    notifications = System.instance.notifications.send(current_notification_view_mode)

    if current_notification_view_mode == "unread"
      notifications = notifications.sort do |a, b|
        a.params[:priority] <=> b.params[:priority]
      end
    end

    render(partial: "show", locals: {
      notification_view_modes: notification_view_modes,
      current_notification_view_mode: current_notification_view_mode,
      errors: notifications,
      admins: AdminUser.admin
    })
  end
end
