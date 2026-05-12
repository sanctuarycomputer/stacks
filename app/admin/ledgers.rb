ActiveAdmin.register Ledger do
  menu false
  config.filters = false
  config.paginate = false
  actions :show
  permit_params
end
