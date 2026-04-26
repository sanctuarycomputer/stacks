ActiveAdmin.register OptixAccountPlan do
  menu parent: "Optix", priority: 5, label: "Account Plans"
  config.filters = false
  actions :index, :show

  scope :all, default: true
  scope("Active") { |s| s.active }
  scope("In trial") { |s| s.in_trial }
  scope("Paying (Active or In trial)") { |s| s.paying }

  index download_links: false do
    column "Status" do |p|
      status_tag(p.status, class: (p.status == "ACTIVE" ? "ok" : nil))
    end
    column "Tier" do |p|
      p.optix_plan_template&.name
    end
    column "Member" do |p|
      p.access_usage_user&.email
    end
    column :price
    column "Start" do |p|
      p.start_timestamp ? Time.at(p.start_timestamp).to_date : "—"
    end
    column "End" do |p|
      p.end_timestamp ? Time.at(p.end_timestamp).to_date : "—"
    end
    actions
  end

  show do
    attributes_table do
      row :optix_id
      row("Status") { |p| status_tag(p.status, class: (p.status == "ACTIVE" ? "ok" : nil)) }
      row("Tier") { |p|
        p.optix_plan_template ? link_to(p.optix_plan_template.name, admin_optix_plan_template_path(p.optix_plan_template)) : "—"
      }
      row("Member (access user)") { |p|
        p.access_usage_user ? link_to(p.access_usage_user.email, admin_optix_user_path(p.access_usage_user)) : "—"
      }
      row :payer_account_optix_id
      row :name
      row :price
      row :price_frequency
      row("Start") { |p| p.start_timestamp ? Time.at(p.start_timestamp) : "—" }
      row("End")   { |p| p.end_timestamp   ? Time.at(p.end_timestamp)   : "—" }
      row("Canceled") { |p| p.canceled_timestamp ? Time.at(p.canceled_timestamp) : "—" }
      row("Created") { |p| p.created_timestamp ? Time.at(p.created_timestamp) : "—" }
      row :synced_at
    end

    panel "Locations available via this plan" do
      table_for resource.optix_locations do
        column(:name) { |l| link_to l.name, admin_optix_location_path(l) }
        column(:city)
        column(:country)
      end
    end

    panel "Raw Optix payload" do
      pre JSON.pretty_generate(resource.data || {})
    end
  end
end
