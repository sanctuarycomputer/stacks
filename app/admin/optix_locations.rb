ActiveAdmin.register OptixLocation do
  menu parent: "Optix", priority: 3, label: "Locations"
  config.filters = false
  actions :index, :show

  index download_links: false do
    column :name
    column :city
    column :region
    column :country
    column :timezone
    column :is_visible
    column :is_hidden
    column :is_deleted
    column :synced_at
    actions
  end

  show do
    attributes_table do
      row :optix_id
      row :name
      row :city
      row :region
      row :country
      row :timezone
      row :is_visible
      row :is_hidden
      row :is_deleted
      row :synced_at
    end

    panel "Plan templates available here" do
      table_for resource.optix_plan_templates do
        column(:name) { |t| link_to t.name, admin_optix_plan_template_path(t) }
        column(:price)
        column(:price_frequency)
        column(:in_all_locations)
      end
    end

    panel "Active members on plans available at this location" do
      counts = resource.optix_plan_templates
        .joins(:optix_account_plans)
        .where(optix_account_plans: { status: %w[ACTIVE IN_TRIAL] })
        .group("optix_plan_templates.name")
        .count("optix_account_plans.optix_id")

      if counts.any?
        table_for counts.map { |tier, n| { tier: tier, count: n } }.sort_by { |r| r[:tier] } do
          column("Tier") { |r| r[:tier] }
          column("Active members") { |r| r[:count] }
        end
      else
        para "No active members on any plan available here."
      end
    end

    panel "Raw Optix payload" do
      pre JSON.pretty_generate(resource.data || {})
    end
  end
end
