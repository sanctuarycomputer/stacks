ActiveAdmin.register Ledger do
  menu false
  config.filters = false
  config.paginate = false
  # :index is needed so admin_ledgers_path exists — the breadcrumb on nested
  # resources (e.g. /admin/ledgers/:id/contributor_adjustments/new) links to
  # the parent's index. Without it, the breadcrumb link is missing.
  actions :index, :show
  permit_params
end
