ActiveAdmin.register ProjectTracker do
  menu label: "Projects", priority: 2
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  actions :index, :new, :show, :edit, :update, :create, :destroy

  permit_params :name,
    :budget_low_end,
    :budget_high_end,
    :notes,
    :atc_id,
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
    ],
    atc_periods_attributes: [
      :id,
      :admin_user_id,
      :started_at,
      :ended_at,
      :_destroy,
      :_edit
    ]

  index download_links: false, title: "Projects" do
    column :name
    column :budget_status do |resource|
      span(resource.status.to_s.humanize.capitalize, class: "pill #{resource.status}")
    end
    column :work_status do |resource|
      span(resource.work_status.to_s.humanize.capitalize, class: "pill #{resource.work_status}")
    end
    column :forecast_projects do |resource|
      if resource.forecast_projects.any?
        div(
          resource.forecast_projects.map do |fp|
            a(fp.display_name, { href: fp.link, target: "_blank", class: "block" })
          end
        )
      else
        span("No Forecast Project Connected", class: "pill error")
      end
    end
    column :ATC do |resource|
      if resource.current_atc.present?
        resource.current_atc
      else
        span("No ATC", class: "pill error")
      end
    end
    actions
  end

  action_item :mark_as_complete, only: :show do
    if resource.work_completed_at.present?
      link_to "Unmark as Work Complete", uncomplete_work_admin_project_tracker_path(resource), method: :post
    else
      link_to "Mark as Work Complete", complete_work_admin_project_tracker_path(resource), method: :post
    end
  end

  member_action :complete_work, method: :post do
    resource.update!(work_completed_at: DateTime.now)
    resource.ensure_project_capsule_exists!
    redirect_to admin_project_tracker_path(resource), notice: "Project marked as complete."
  end

  member_action :uncomplete_work, method: :post do
    resource.update!(work_completed_at: nil)
    resource.ensure_project_capsule_exists!
    redirect_to admin_project_tracker_path(resource), notice: "Project unmarked as complete."
  end

  show do
    render 'show'
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :name
      f.input :budget_low_end
      f.input :budget_high_end

      f.has_many :atc_periods, heading: false, allow_destroy: true, new_record: 'Add an ATC' do |a|
        a.input :admin_user
        a.input :started_at, hint: "Leave blank to default to the date of the first recorded hour"
        a.input :ended_at, hint: "Leave blank unless ATC role was passed off to another person"
      end

      f.has_many :project_tracker_links, heading: false, allow_destroy: true, new_record: 'Add a Project URL' do |a|
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

      f.input :notes, label: "Notes (accepts markdown)"
    end

    f.actions
  end
end
