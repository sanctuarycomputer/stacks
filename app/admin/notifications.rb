ActiveAdmin.register Notification do
  menu priority: 1, label: proc {
    count = current_admin_user.notifications.unread.count
    div(count, class: "notifier") if count > 0
    "Inbox"
  }

  scope :unread, default: true
  scope :read
  scope_to :current_admin_user
  config.filters = false
  config.paginate = false
  actions :index, :show
  config.current_filters = false

  index title: "Inbox", download_links: false do
    column :created_at
    column :topic do |resource|
      resource.to_notification.topic
    end
    actions
  end

  action_item :toggle_read, only: :show do
    if resource.read?
      link_to(
        'Mark as Unread',
        toggle_status_admin_notification_path(resource),
        method: :post
      )
    else
      link_to(
        'Mark as Read',
        toggle_status_admin_notification_path(resource),
        method: :post
      )
    end
  end

  member_action :toggle_status, method: :post do
    resource.read? ? resource.mark_as_unread! : resource.mark_as_read!
    redirect_to admin_notifications_path(), notice: "Success!"
  end

  show do
    render(partial: "show", locals: {
      notification: resource.to_notification
    })
  end
end
