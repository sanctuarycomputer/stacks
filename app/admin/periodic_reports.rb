ActiveAdmin.register PeriodicReport do
  menu parent: "Dashboard", label: "Quarterly Reports"

  config.filters = false
  config.paginate = false
  config.sort_order = "period_starts_at_desc"
  actions :index, :show
  scope :all

  index do
    column :period_label
    column :profit_share_status do |resource|
      status =
        if resource.profit_shares.empty?
          resource.notification.present? ? "error" : "not_generated"
        else
          resource.all_profit_shares_accepted? ? "all_accepted" : "some_pending"
        end

      span(status.humanize, class: "pill #{status}")
    end
    column :generated_at do |resource|
      resource.blueprint["generated_at"]
    end
    actions
  end

  show do
    render(partial: 'show', locals: {
      periodic_report: resource
    })
  end
end
