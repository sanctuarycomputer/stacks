ActiveAdmin.register System do
  menu if: -> { current_admin_user.is_admin? },
        priority: 0,
        label: -> {
          div("!", class: "notifier")
          "System"
        },
        url: -> { url_for [:admin, :system] }

  actions :show, :edit, :update
  permit_params settings: [System.storext_definitions.keys]

  action_item :trigger_forecast_sync, only: :show, if: proc { current_admin_user.is_admin? } do
    link_to "Trigger Forecast Sync", trigger_forecast_sync_admin_system_path(resource), method: :post
  end

  member_action :trigger_forecast_sync, method: :post do
    Stacks::Forecast.new.sync_all!
    redirect_to admin_system_path, notice: "Synced!"
  end

  form do |f|
    f.inputs for: :settings do |s|
      s.input :default_hourly_rate,
        as: :number,
        input_html: { value: resource.default_hourly_rate }
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
    render(partial: "show", locals: {
      errors: Stacks::Notifications.notifications,
      admins: AdminUser.admin
    })
  end
end
