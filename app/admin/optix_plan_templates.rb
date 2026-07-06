ActiveAdmin.register OptixPlanTemplate do
  menu parent: "Optix", priority: 4, label: "Plan Templates"
  config.filters = false
  actions :index, :show

  index download_links: false do
    column :name
    column :price
    column :price_frequency
    column :in_all_locations
    column "Locations" do |t|
      t.optix_locations.pluck(:name).join(", ").presence || "—"
    end
    column "Active members" do |t|
      t.optix_account_plans.paying.count
    end
    column "All plans" do |t|
      t.optix_account_plans.count
    end
    actions
  end

  show do
    attributes_table do
      row :optix_id
      row :name
      row :price
      row :price_frequency
      row :in_all_locations
      row :onboarding_enabled
      row :non_onboarding_enabled
      row :synced_at
    end

    panel "Available at" do
      if resource.in_all_locations
        para strong "All locations"
      else
        table_for resource.optix_locations do
          column(:name) { |l| link_to l.name, admin_optix_location_path(l) }
          column(:city)
          column(:country)
        end
      end
    end

    panel "Account plans on this tier" do
      counts = resource.optix_account_plans.group(:status).count
      if counts.any?
        table_for counts.map { |s, n| { status: s, count: n } }.sort_by { |r| r[:status] } do
          column("Status") { |r| status_tag(r[:status], class: (r[:status] == "ACTIVE" ? "ok" : nil)) }
          column("Count") { |r|
            link_to r[:count],
              admin_optix_account_plans_path(q: { optix_plan_template_id_eq: resource.optix_id, status_eq: r[:status] })
          }
        end
      else
        para "No account plans on this tier."
      end
    end

    panel "Raw Optix payload" do
      pre JSON.pretty_generate(resource.data || {})
    end
  end
end
