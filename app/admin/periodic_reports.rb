ActiveAdmin.register PeriodicReport do
  menu parent: "Dashboard", label: "Quarterly Reports"

  config.filters = false
  config.paginate = false
  config.sort_order = "period_starts_at_desc"
  actions :index, :show, :edit, :update
  scope :all

  show do
    render(partial: 'show', locals: {
      periodic_report: resource
    })
  end
end
