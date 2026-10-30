ActiveAdmin.register ProfitShareManualInclusionPeriod do
  menu label: "Profit Share Inclusions", parent: "Money"
  config.filters = false
  config.sort_order = "started_at_desc"
  actions :index, :new, :create, :edit, :update, :destroy
  permit_params :contributor_id, :started_at, :ended_at, :note

  controller do
    def scoped_collection
      super.includes(contributor: :forecast_person)
    end
  end

  index download_links: false, title: "Manual Profit Share Inclusions" do
    column :contributor
    column :started_at
    column :ended_at
    column :note
    actions
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      f.input :contributor,
        collection: Contributor.includes(:forecast_person).map { |c| [c.display_name, c.id] }
      # One field per date, as MSO Roles: a blank year in date selects would
      # silently save an open-ended period.
      f.input :started_at, as: :datepicker, hint: "Must be the first day of a month"
      f.input :ended_at, as: :datepicker,
        hint: "Leave blank while they're included. Otherwise the last day of a month."
      f.input :note, hint: "Why they're included, e.g. \"garden3d ops, does Sanctuary client work\". " \
        "If they're not on Deel, set their cost-of-living country on their contributor page first, " \
        "or the profit share sync will stop and name them."
    end
    f.actions
  end
end
