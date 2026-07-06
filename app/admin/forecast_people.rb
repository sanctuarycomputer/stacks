ActiveAdmin.register ForecastPerson do
  config.filters = false
  config.paginate = false
  menu false
  actions :index, :show

  scope :active, default: true
  scope :archived

  index download_links: false do
    column :email
    actions
  end
end
