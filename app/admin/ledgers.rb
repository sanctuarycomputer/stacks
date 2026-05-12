ActiveAdmin.register Ledger do
  menu false
  config.filters = false
  config.paginate = false
  # :index is needed so admin_ledgers_path exists — ActiveAdmin's breadcrumb
  # on nested resources (e.g. /admin/ledgers/:id/contributor_adjustments/new)
  # generates a polymorphic link to the parent's index. Without it, page
  # rendering raises "Please use symbols for polymorphic route arguments."
  actions :index, :show
  permit_params
end
