ActiveAdmin.register ProjectTracker do
  menu label: "Projects"
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  actions :index, :new, :show, :edit, :update, :create, :destroy

  permit_params :name,
    :budget_low_end,
    :budget_high_end,
    :notes,
    project_tracker_links_attributes: [
      :id,
      :name,
      :url,
      :link_tracker,
      :project_tracker_id,
      :_destroy,
      :_edit
    ],
    project_tracker_forecast_projects_attributes: [
      :id,
      :forecast_project_id,
      :_destroy,
      :_edit
    ]

  index download_links: false do
    column :name
    column :status do |resource|
      span(resource.status.to_s.humanize.capitalize, class: "pill #{resource.status}")
    end
    column :forecast_projects
    actions do |resource|
      proposal_link = resource.project_tracker_links.find do |ptl|
        ptl.link_type == "proposal"
      end
      link_to "Proposal ↗", proposal_link.url, target: "_blank" if proposal_link.present?
    end
  end

  show do
    render 'show'
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :name
      f.input :budget_low_end
      f.input :budget_high_end

      f.has_many :project_tracker_links, heading: false, allow_destroy: true, new_record: 'Create a Project Link' do |a|
        a.input(:name, {
          label: "Link Name",
          prompt: "Add a name for this link",
        })
        a.input(:url, {
          label: "Link URL",
          prompt: "Add a name for this link",
        })
        a.input(:link_type, {
          label: "Link Type",
          prompt: "Choose a type for this link",
        })
      end

      f.has_many :project_tracker_forecast_projects, heading: false, allow_destroy: true, new_record: 'Connect a Forecast Project' do |a|
        a.input(:forecast_project, {
          label: "Forecast Project",
          prompt: "Select a Forecast Project",
          collection: ForecastProject.active
        })
      end

      f.input :notes
    end

    f.actions
  end
end
