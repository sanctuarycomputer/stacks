ActiveAdmin.register CollectiveRole do
  menu label: "Collective Roles", parent: "Team"
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  actions :index, :new, :edit, :update, :create, :destroy
  config.current_filters = false

  permit_params :name,
    :notion_link,
    collective_role_holder_periods_attributes: [
      :id,
      :admin_user_id,
      :started_at,
      :ended_at,
      :_destroy,
      :_edit
    ]

  index download_links: false, title: "g3d Collective Roles" do
    column :name do |resource|
      if resource.notion_link.present?
        a("#{resource.name} ↗", { href: resource.notion_link, target: "_blank", class: "block", style: "white-space:nowrap" })
      else
        resource.name
      end
    end
    column "Current Role Holder", :current_role_holder do |resource|
      if resource.current_collective_role_holders
        resource.current_collective_role_holders.first
      else
        span("No #{resource.name}", class: "pill error")
      end
    end
    actions
  end

  form do |f|
    f.inputs(class: "admin_inputs") do

      f.semantic_errors
      f.input :name
      f.input :notion_link

      f.has_many :collective_role_holder_periods, heading: false, allow_destroy: true, new_record: 'Add a Collective Role Holder' do |a|
        a.input :admin_user
        a.input :started_at,
          hint: "Leave blank to mean since Jan 1st, 2024 (when these roles are effective from)"
        a.input :ended_at,
          hint: "Leave blank unless this role was passed off to another person"
      end
    end

    f.actions
  end
end
