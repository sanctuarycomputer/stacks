ActiveAdmin.register Trueup do
  config.filters = false
  config.paginate = false
  actions :index, :show, :destroy
  menu false

  belongs_to :contributor

  index download_links: false do
    column :contributor
    column :amount
    column :payment_date
    actions
  end
end
