ActiveAdmin.register SystemTask do
  menu if: -> { current_admin_user.is_admin? },
        priority: 0,
        label: -> {
          div("#{SystemTask.in_progress.count}", class: "notifier")
          "System Tasks"
        }

  config.filters = false
  config.paginate = true
  actions :index, :show
  config.current_filters = false

  scope :in_progress, default: true
  scope :success
  scope :error

  index download_links: false do
    column :name
    column :started_at do |resource|
      "#{time_ago_in_words(resource.created_at)} ago"
    end

    if ["success", "error"].include?(params["scope"])
      column :settled_at do |resource|
        "#{time_ago_in_words(resource.settled_at)} ago"
      end
    end

    if ["error"].include?(params["scope"])
      column :notification do |resource|
        resource.notification
      end
    end

    column :time_taken_in_minutes do |resource|
      "#{(resource.time_taken_in_minutes).round(2)} minutes"
    end
    actions
  end
end
