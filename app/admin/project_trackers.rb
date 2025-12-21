ActiveAdmin.register ProjectTracker do
  menu label: "Projects", priority: 2
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  actions :index, :new, :show, :edit, :update, :create, :destroy
  config.current_filters = false

  scope :in_progress, default: true
  scope :dormant
  scope :complete

  permit_params :name,
    :budget_low_end,
    :budget_high_end,
    :target_profit_margin,
    :target_free_hours_percent,
    :notes,
    :runn_project_id,
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
      :link_type,
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
    project_lead_periods_attributes: [
      :id,
      :admin_user_id,
      :studio_id,
      :started_at,
      :ended_at,
      :_destroy,
      :_edit
    ],
    project_safety_representative_periods_attributes: [
      :id,
      :admin_user_id,
      :studio_id,
      :started_at,
      :ended_at,
      :_destroy,
      :_edit
    ],
    creative_lead_periods_attributes: [
      :id,
      :admin_user_id,
      :studio_id,
      :started_at,
      :ended_at,
      :_destroy,
      :_edit
    ],
    technical_lead_periods_attributes: [
      :id,
      :admin_user_id,
      :studio_id,
      :started_at,
      :ended_at,
      :_destroy,
      :_edit
    ]

  controller do
    def new
      build_resource
      resource.project_tracker_links << ProjectTrackerLink.new({
        name: "MSA",
        link_type: :msa
      })
      resource.project_tracker_links << ProjectTrackerLink.new({
        name: "SOW/PD",
        link_type: :sow
      })
      new!
    end

    def scoped_collection
      super.includes(
        :project_lead_periods,
        :project_capsule,
        :project_tracker_forecast_projects,
        :forecast_projects,
        :adhoc_invoice_trackers,
      ).includes(
        project_lead_periods: :admin_user,
        creative_lead_periods: :admin_user,
        technical_lead_periods: :admin_user,
        project_safety_representative_periods: :admin_user,
        account_lead_periods: :admin_user,
        team_lead_periods: :admin_user,
        adhoc_invoice_trackers: :qbo_invoice
      )
    end
  end

  csv do
    column :name
    column :budget_low_end
    column :budget_high_end
    column :spend
    column :income
    column :estimated_cost do |pt|
      pt.estimated_cost
    end
    column :profit
    column :profit_margin
    column :total_hours
    column :total_free_hours
    column :free_hours_ratio do |pt|
      pt.free_hours_ratio * 100
    end
    column :last_recorded_assignment do |pt|
      pt.last_recorded_assignment.try(:end_date)
    end
  end

  index download_links: [:csv], title: "Projects" do
    column :considered_successful?

    if params["scope"] == "complete"
      column :project_satisfaction_survey do |pt|
        if pt&.project_capsule&.project_satisfaction_survey&.closed_at&.present?
          score = pt.project_capsule.project_satisfaction_survey.results[:overall].round(1)
          pill_class =
            if score >= 4.5
              "exceptional"
            elsif score >= 3.5
              "healthy"
            elsif score >= 2.5
              "at_risk"
            else
              "failing"
            end

          span("#{score} / 5", class: "pill #{pill_class}")
        else
          "No survey"
        end
      end
      column :last_recorded_assignment do |pt|
        pt.last_recorded_assignment.try(:end_date)
      end
    end

    column :name

    column :hours do |resource|
      free_hours = resource.total_free_hours
      total_hours = resource.total_hours
      free_hours_percentage = resource.free_hours_ratio * 100

      pill_class =
        if free_hours_percentage == 0
          "exceptional"
        elsif free_hours_percentage < 1
          "healthy"
        elsif free_hours_percentage < 5
          "at_risk"
        else
          "failing"
        end

      div([
        span(class: "pill #{pill_class}") do
          span(class: "split") do
            [strong("#{total_hours.round} hrs,"), span("#{free_hours.round} free")]
          end
        end,
        para(class: "okr_hint") do
          "#{free_hours_percentage.round(1)}% hrs billed at $0p/h"
        end
      ])
    end
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
            a("#{fp.display_name} ↗", { href: fp.link, target: "_blank", class: "block", style: "white-space:nowrap" })
          end
        )
      else
        span("No Forecast Project/s Connected", class: "pill error")
      end
    end

    column "Account Lead (AL)", :account_leads do |resource|
      if resource.current_account_leads.any?
        resource.current_account_leads
      else
        span("No Account Lead", class: "pill error")
      end
    end
    column "Team Lead (TL)", :team_leads do |resource|
      if resource.current_team_leads.any?
        resource.current_team_leads
      else
        span("No Team Lead", class: "pill error")
      end
    end

    column "Runn.io Project", :runn_project do |resource|
      if resource.runn_project.present?
        a("#{resource.runn_project.name} ↗", { href: resource.runn_project.link, target: "_blank", class: "block", style: "white-space:nowrap" })
      else
        span("No Runn.io Project Connected", class: "pill error")
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

  action_item :edit_account_leads, only: [:show, :edit] do
    link_to "Edit Account Lead", admin_project_tracker_account_lead_periods_path(resource)
  end

  action_item :edit_team_leads, only: [:show, :edit] do
    link_to "Edit Team Lead", admin_project_tracker_team_lead_periods_path(resource)
  end

  member_action :complete_work, method: :post do
    resource.update_column(:work_completed_at, DateTime.now)
    resource.ensure_project_capsule_exists!
    redirect_to admin_project_tracker_path(resource), notice: "Project marked as complete."
  end

  member_action :uncomplete_work, method: :post do
    resource.update_column(:work_completed_at, nil)
    resource.ensure_project_capsule_exists!
    redirect_to admin_project_tracker_path(resource), notice: "Project unmarked as complete."
  end

  show do
    accounting_method = session[:accounting_method] || "cash"

    start_date =
      resource.first_recorded_assignment&.start_date&.iso8601 || DateTime.now.iso8601
    end_date =
      resource.last_recorded_assignment&.end_date&.iso8601 || DateTime.now.iso8601

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
         x: start_date,
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
           y: acc[:income_total] += (it.qbo_line_items_relating_to_forecast_projects(
             resource.forecast_projects
           ).map{|qbo_li| qbo_li.dig("amount").to_f}.reduce(&:+) || 0)
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
      income_data[:income].reduce(end_date) do |acc, datapoint|
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
            min: start_date,
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
          x: start_date,
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
          x: start_date,
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

    if resource.snapshot["cost"]
      burnup_data[:data][:datasets].push({
        backgroundColor: Stacks::Utils::COLORS[2], # color of dots
        borderColor: Stacks::Utils::COLORS[8], # color of line
        label: "Cost",
        data: resource.snapshot["cost"],
        pointRadius: 1
      })
    end

    render(partial: 'show', locals: {
      burnup_data: burnup_data
    })
  end

  form do |f|
    f.inputs(class: "admin_inputs") do

      f.semantic_errors
      f.input :name
      f.input :budget_low_end
      f.input :budget_high_end

      if current_admin_user.is_admin?
        f.input :company_treasury_split, hint: "The percentage of the project's profit that will be allocated to the company treasury. This is used to calculate the project's profit margin."
        f.input :target_profit_margin, hint: "The target profit margin for the project. This is used to calculate the project's profit margin."
        f.input :target_free_hours_percent, hint: "The target free hours percent for the project. This is used to calculate the project's free hours ratio."
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
        a.input :qbo_invoice,
          as: :select,
          collection: QboInvoice.orphans
      end

      f.has_many :project_tracker_forecast_projects, heading: false, allow_destroy: true, new_record: 'Connect a Forecast Project' do |a|
        a.input(:forecast_project, {
          label: "Forecast Project",
          prompt: "Select a Forecast Project",
          collection: ForecastProject.candidates_for_association_with_project_tracker(resource),
          hint: "Is your project disabled? That's likely because it's Forecast Project Code is claimed by another Stacks Project Tracker. Choose a unique code for Forecast Projects associated with this Project Tracker. We sync with Forecast every ~10 minutes or so, so if you make changes there, check back here after 10 minutes."
        })
      end

      f.input :runn_project,
        as: :select,
        collection: RunnProject.candidates_for_association_with_project_tracker(resource),
        hint: "Runn.io Project missing? Check first it's not tentative or archived in Runn.io; and it should appear in this list after about 10 minutes."

      f.input :notes, label: "Notes (accepts markdown)"
    end

    f.actions
  end
end
