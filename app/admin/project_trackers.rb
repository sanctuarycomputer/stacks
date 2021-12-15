ActiveAdmin.register ProjectTracker do
  menu label: "Projects"
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  actions :index, :new, :show, :edit, :update, :create, :destroy

  permit_params :name,
    :budget_low_end,
    :budget_high_end,
    :notion_proposal_url,
    :notes,
    project_tracker_forecast_projects_attributes: [:id, :forecast_project_id, :_destroy, :_edit]

  index download_links: false do
    column :name
    column :budget_low_end do |resource|
      number_to_currency(resource.budget_low_end)
    end
    column :budget_high_end do |resource|
      number_to_currency(resource.budget_high_end)
    end
    column :status do |resource|
      span(resource.status.to_s.humanize.capitalize, class: "pill #{resource.status}")
    end
    actions do |resource|
      link_to "Proposal ↗", resource.notion_proposal_url if resource.notion_proposal_url.present?
    end
  end

  show do
    render 'show'
  end

  form do |f|
    forecast = Stacks::Forecast.new
    projects = forecast.projects()["projects"].map do |p|
      {
        forecast_id: p["id"],
        data: p,
      }
    end
    ForecastProject.upsert_all(projects, unique_by: :forecast_id)

    f.inputs(class: "admin_inputs") do
      f.input :name
      f.input :budget_low_end
      f.input :budget_high_end
      f.input :notion_proposal_url

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
