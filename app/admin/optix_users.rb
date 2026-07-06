ActiveAdmin.register OptixUser do
  menu parent: "Optix", priority: 2, label: "Users"
  config.filters = false
  actions :index, :show

  scope :all, default: true
  scope :with_active_plan

  index download_links: false do
    column :email
    column :name
    column :is_active
    column "Active plan?" do |u|
      u.active_member? ? status_tag("Yes", class: "ok") : status_tag("No")
    end
    column "Current tier" do |u|
      u.current_tier_name
    end
    column "Synced" do |u|
      u.synced_at&.to_date
    end
    actions
  end

  show do
    attributes_table do
      row :optix_id
      row :email
      row :name
      row :last_name
      row :is_active
      row("Active member?") { |u| u.active_member? ? status_tag("Yes", class: "ok") : status_tag("No") }
      row("Current tier") { |u| u.current_tier_name }
      row :synced_at
    end

    panel "Account Plans" do
      table_for resource.optix_account_plans.order(start_timestamp: :desc) do
        column("Status") { |p| status_tag(p.status, class: (p.status == "ACTIVE" ? "ok" : nil)) }
        column("Tier") { |p| p.optix_plan_template&.name }
        column("Price") { |p| p.price ? "$#{p.price} / #{p.price_frequency}" : "—" }
        column("Start") { |p| p.start_timestamp ? Time.at(p.start_timestamp).to_date : "—" }
        column("End") { |p| p.end_timestamp ? Time.at(p.end_timestamp).to_date : "—" }
        column("Canceled") { |p| p.canceled_timestamp ? Time.at(p.canceled_timestamp).to_date : "—" }
        column("Details") { |p| link_to "View →", admin_optix_account_plan_path(p) }
      end
    end

    panel "Raw Optix payload" do
      pre JSON.pretty_generate(resource.data || {})
    end
  end
end
