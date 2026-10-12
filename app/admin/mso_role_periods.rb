ActiveAdmin.register MsoRolePeriod do
  menu label: "MSO Roles", parent: "Money"
  config.filters = false
  config.sort_order = "started_at_desc"
  actions :index, :new, :create, :edit, :update, :destroy
  permit_params :contributor_id, :tier, :title, :started_at, :ended_at

  controller do
    def scoped_collection
      super.includes(contributor: :forecast_person)
    end
  end

  index download_links: false, title: "MSO Roles" do
    column :contributor
    column(:tier) { |period| period.tier.titleize }
    column :title
    column(:multiplier) { |period| "#{period.tier_multiplier.to_s('F')}x" }
    column :started_at
    column :ended_at
    actions
  end

  form do |f|
    f.inputs do
      f.semantic_errors
      f.input :contributor,
        collection: Contributor.includes(:forecast_person).map { |c| [c.display_name, c.id] }
      f.input :tier, as: :select, collection: MsoRolePeriod.tiers.keys.map { |t| [t.titleize, t] },
        include_blank: false
      f.input :title, hint: "e.g. Operations — shown as \"Chief (Operations)\""
      # One field per date, not three dropdowns: with year/month/day selects a
      # blank year silently saves an empty end date, which makes the role
      # open-ended and changes who counts as a current executive.
      f.input :started_at, as: :datepicker, hint: "Must be the first day of a month"
      f.input :ended_at, as: :datepicker,
        hint: "Leave blank while the role is held. Otherwise the last day of a month."
    end
    f.actions
  end
end
