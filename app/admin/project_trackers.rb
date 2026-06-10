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
    commissions_attributes: [
      :id,
      :type,
      :contributor_id,
      :rate,
      :notes,
      :_destroy,
      :_edit,
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
        :runn_project,
        :forecast_projects,
        { project_capsule: :project_satisfaction_survey },
        { project_tracker_forecast_projects: :forecast_project },
        { adhoc_invoice_trackers: :qbo_invoice },
        { account_lead_periods: :admin_user },
        { project_lead_periods: :admin_user }
      )
    end

    def collection
      c = super
      if action_name == "index" && !@_preloaded_for_render
        arr = c.to_a
        ProjectTracker.preload_for_render(arr)
        @_preloaded_for_render = true
        # Group by account lead on the Active and Dormant tabs (and on the
        # default unfiltered view). Within each lead, fall back to the
        # config-level `created_at DESC` tiebreaker. Trackers with no current
        # account lead sort last.
        if %w[in_progress dormant].include?(params["scope"]) || params["scope"].blank?
          sorted = arr.sort_by do |pt|
            first_lead = pt.current_account_leads.map { |au| au&.name.to_s }.reject(&:empty?).sort.first
            [first_lead.nil? ? 1 : 0, (first_lead || "").downcase, -pt.created_at.to_i]
          end
          # `paginated_collection` (AA view helper) requires a Kaminari-style
          # page/per interface even when `config.paginate = false`. A bare
          # Array doesn't qualify, so wrap with Kaminari.paginate_array.
          @_index_array = Kaminari.paginate_array(sorted).page(1).per(sorted.size.nonzero? || 1)
        end
      end
      @_index_array || c
    end
  end

  index download_links: false, title: "Projects" do
    column :considered_successful?

    if params["scope"] == "complete"
      column :project_satisfaction_survey do |pt|
        survey = pt&.project_capsule&.project_satisfaction_survey
        if survey&.closed_at&.present?
          raw = survey.score || survey.overall_rating_from_question_responses
          score = raw.nil? ? nil : raw.to_f.round(1)
          if score.nil?
            span("No responses", class: "pill error")
          else
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
          end
        else
          "No survey"
        end
      end
      column :last_recorded_assignment do |pt|
        pt.last_recorded_assignment_end_date
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
    column "Project Lead (PL)", :project_leads do |resource|
      if resource.current_project_leads.any?
        resource.current_project_leads
      else
        span("No Project Lead", class: "pill error")
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

  action_item :edit_project_leads, only: [:show, :edit] do
    link_to "Edit Project Lead", admin_project_tracker_project_lead_periods_path(resource)
  end

  # Shown on any project tracker that doesn't have a linked Runn project
  # yet. The action handler matches the tracker's forecast_client to a
  # Runn client by exact (case-insensitive, trimmed) name — if no client
  # with that name exists in Runn, the admin gets a flash error telling
  # them to either create the Runn client first or rename to match.
  action_item :create_runn_project, only: [:show, :edit] do
    next if resource.runn_project.present?
    link_to "Create Runn Project ↗", create_runn_project_admin_project_tracker_path(resource), method: :post
  end

  member_action :create_runn_project, method: :post do
    if resource.runn_project.present?
      redirect_to admin_project_tracker_path(resource), alert: "This project tracker is already linked to a Runn project."
      next
    end

    fc = resource.forecast_projects.first&.forecast_client
    if fc.nil?
      redirect_to admin_project_tracker_path(resource), alert: "This project tracker has no Forecast client to match against."
      next
    end

    begin
      runn = Stacks::Runn.new
      target_name = fc.name.to_s.strip.downcase
      match = runn.get_clients.find do |c|
        next if c["isArchived"]
        c["name"].to_s.strip.downcase == target_name
      end

      if match.nil?
        redirect_to admin_project_tracker_path(resource),
          alert: "Couldn't find an active Runn client named #{fc.name.inspect}. Create it in Runn first (or rename so the names match), then try again."
        next
      end

      created = runn.create_project(resource.name, match["id"])

      # External API call done — the project exists in Runn. Wrap only the
      # local DB writes in a transaction so we don't end up with a local
      # RunnProject row that isn't linked to the project tracker (which
      # would cause the next click to create a DUPLICATE Runn project).
      # Don't put the API call inside the transaction — it'd hold a DB
      # connection open for the round-trip.
      rp = nil
      ActiveRecord::Base.transaction do
        rp = RunnProject.create!(
          runn_id: created["id"],
          name: created["name"],
          is_template: created["isTemplate"],
          is_archived: created["isArchived"],
          is_confirmed: created["isConfirmed"],
          pricing_model: created["pricingModel"],
          rate_type: created["rateType"],
          budget: created["budget"],
          expenses_budget: created["expensesBudget"],
          data: created,
        )
        resource.update!(runn_project: rp)
      end
      redirect_to admin_project_tracker_path(resource), notice: "Created Runn project ##{rp.runn_id} (#{rp.name}) and linked it."
    rescue => e
      redirect_to admin_project_tracker_path(resource),
        alert: "Failed to create Runn project: #{e.message.to_s.slice(0, 200)}"
    end
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
      resource.first_recorded_assignment_start_date&.iso8601 || DateTime.now.iso8601
    end_date =
      resource.last_recorded_assignment_end_date&.iso8601 || DateTime.now.iso8601

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

  sidebar "QBO Bill Account Mappings", only: :show do
    mappings = QboBillAccountMapping.where(project_tracker_id: resource.id).includes(:enterprise)
    if mappings.any?
      table_for mappings do
        column("Enterprise") { |m| m.enterprise.name }
        column("Line item", :line_item_key)
        column("Account") { |m| m.chart_account&.display_label || m.qbo_chart_account_qbo_id }
        column("") { |m| link_to "Edit", edit_admin_qbo_bill_account_mapping_path(m) }
      end
    else
      para "No project-specific account overrides."
    end
    div do
      link_to "Add override", new_admin_qbo_bill_account_mapping_path(
        qbo_bill_account_mapping: { project_tracker_id: resource.id },
      )
    end
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

      f.has_many :commissions, heading: "Commissions (paid back-of-house, deducted from each invoice line before contributor payouts)", allow_destroy: true, new_record: 'Add a Commission' do |c|
        c.input :type,
          as: :select,
          collection: [
            ["Percentage of line amount", "PercentageCommission"],
            ["Per billable hour", "PerHourCommission"],
          ],
          prompt: "Choose commission type"
        c.input :contributor,
          as: :select,
          collection: Contributor.includes(:forecast_person).map { |co| [co.display_name, co.id] },
          prompt: "Choose recipient (Contributor)"
        c.input :rate, hint: "For Percentage: 0.15 = 15%. For Per Hour: dollar amount per billable hour (e.g. 15.00)."
        c.input :notes, as: :text, input_html: { rows: 2 }
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
