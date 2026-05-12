ActiveAdmin.register Ledger do
  menu false
  belongs_to :contributor, optional: true
  config.filters = false
  config.paginate = false
  actions :show
  permit_params
end
