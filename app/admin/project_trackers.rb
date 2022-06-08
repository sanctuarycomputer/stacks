ActiveAdmin.register ProjectTracker do
  menu label: "Projects", priority: 2
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  actions :index, :new, :show, :edit, :update, :create, :destroy
  config.current_filters = false

  scope :in_progress, default: true
  scope :complete

  permit_params :name,
    :budget_low_end,
    :budget_high_end,
    :notes,
    :atc_id,
    adhoc_invoice_trackers_attributes: [
      :id,
      :qbo_invoice_id,
      :_destroy,
      :_edit
    ],
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

  controller do
    def scoped_collection
      super.includes(
        :atc_periods,
        :project_capsule,
        :project_tracker_forecast_projects,
        :forecast_projects,
        :adhoc_invoice_trackers,
      ).includes(
        atc_periods: :admin_user,
        adhoc_invoice_trackers: :qbo_invoice
      )
    end
  end

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
    income_data = [
      *resource.invoice_trackers,
      *resource.adhoc_invoice_trackers
    ].reject{|i| i.qbo_invoice.nil?}
     .sort do |a, b|
        ((a.qbo_invoice.try(:data) || {}).dig("due_date") || a.created_at.to_date.iso8601) <=>
        ((b.qbo_invoice.try(:data) || {}).dig("due_date") || b.created_at.to_date.iso8601)
     end
     .reduce({
       income: [{
         x: resource.first_recorded_assignment.start_date.iso8601,
         y: 0
       }],
       income_total: 0
     }) do |acc, it|
       if it.is_a?(InvoiceTracker)
         acc[:income].push({
           x: (
             (it.qbo_invoice.try(:data) || {}).dig("due_date") ||
             it.created_at.to_date.iso8601
           ),
           y: acc[:income_total] += it.qbo_line_items_relating_to_forecast_projects(
             resource.forecast_projects
           ).map{|qbo_li| qbo_li.dig("amount").to_f}.reduce(&:+)
         })
       else
         acc[:income].push({
           x: (
             (it.qbo_invoice.try(:data) || {}).dig("due_date") ||
             it.created_at.to_date.iso8601
           ),
           y: acc[:income_total] += it.qbo_invoice.try(:total).to_f
         })
       end
       acc
     end

    latest_timestamp =
      income_data[:income].reduce(
        resource.last_recorded_assignment.end_date.iso8601
      ) do |acc, datapoint|
        next datapoint[:x] if Date.parse(acc) < Date.parse(datapoint[:x])
        acc
      end

    burnup_data = {
      type: 'line',
      data: {
        datasets: []
      },
      options: {
        scales: {
          x: {
            type: 'time',
            min: resource.first_recorded_assignment.start_date.iso8601,
            max: latest_timestamp,
            time: {
              unit: 'month'
            }
          },
          y: {
            beginAtZero: true
          }
        }
      },
    }

    if resource.budget_low_end.present?
      burnup_data[:data][:datasets].push({
        label: "Budget Low End",
        borderDash: [5, 5],
        backgroundColor: Stacks::Utils::COLORS[1], # color of dots
        borderColor: Stacks::Utils::COLORS[6], # color of line
        pointRadius: 0,
        data: [{
          x: resource.first_recorded_assignment.start_date.iso8601,
          y: resource.budget_low_end
        }, {
          x: latest_timestamp,
          y: resource.budget_low_end
        }]
      })
    end

    if resource.budget_high_end.present?
      burnup_data[:data][:datasets].push({
        label: "Budget High End",
        backgroundColor: Stacks::Utils::COLORS[14], # color of dots
        borderColor: Stacks::Utils::COLORS[4], # color of line
        pointRadius: 0,
        data: [{
          x: resource.first_recorded_assignment.start_date.iso8601,
          y: resource.budget_high_end
        }, {
          x: latest_timestamp,
          y: resource.budget_high_end
        }]
      })
    end

    burnup_data[:data][:datasets].push({
      backgroundColor: Stacks::Utils::COLORS[3], # color of dots
      borderColor: Stacks::Utils::COLORS[7], # color of line
      label: "Income",
      data: income_data[:income],
      pointRadius: 0
    })

    if resource.snapshot["spend"]
      burnup_data[:data][:datasets].push({
        backgroundColor: Stacks::Utils::COLORS[0], # color of dots
        borderColor: Stacks::Utils::COLORS[5], # color of line
        label: "Spend",
        data: resource.snapshot["spend"],
        pointRadius: 1
      })
    end

    if resource.snapshot["cogs"]
      burnup_data[:data][:datasets].push({
        borderColor: Stacks::Utils::COLORS[2], # color of dots
        backgroundColor: Stacks::Utils::COLORS[8], # color of line
        label: "COGS",
        data: resource.snapshot["cogs"],
        pointRadius: 1
      })
    end

    if resource.snapshot["cost"]
      burnup_data[:data][:datasets].push({
        backgroundColor: Stacks::Utils::COLORS[2], # color of dots
        borderColor: Stacks::Utils::COLORS[8], # color of line
        label: "Cost of Labor",
        data: resource.snapshot["cost"],
        pointRadius: 1,
      })
    end

    render(partial: 'show', locals: {
      burnup_data: burnup_data
    })
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :name
      f.input :budget_low_end
      f.input :budget_high_end

      f.has_many :atc_periods, heading: false, allow_destroy: true, new_record: 'Add an ATC' do |a|
        a.input :admin_user
        a.input :started_at,
          hint: "Leave blank to default to the date of the first recorded hour"
        a.input :ended_at,
          hint: "Leave blank unless this ATC role was passed off to another person"
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

      f.has_many :adhoc_invoice_trackers, heading: false, allow_destroy: true, new_record: 'Connect an Adhoc Invoice' do |a|
        a.input :qbo_invoice
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
