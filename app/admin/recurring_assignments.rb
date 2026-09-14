ActiveAdmin.register RecurringAssignment do
  menu label: "Recurring Assignments", parent: "Team"
  config.filters = false
  actions :index, :new, :create, :edit, :update, :destroy, :show

  # Integer values (not strings): Formtastic's check_boxes marks a box checked via
  # selected_values.include?(value), comparing against the record's integer weekdays.
  # String values here would never match, so every box would render unchecked.
  WEEKDAY_CHOICES = [["Mon", 1], ["Tue", 2], ["Wed", 3], ["Thu", 4], ["Fri", 5], ["Sat", 6], ["Sun", 0]].freeze

  permit_params :forecast_person_id, :forecast_project_id, :allocation_in_hours,
    :active_on_days_off, :notes, :starts_on, :ends_on, :paused_at, weekdays: []

  controller do
    def scoped_collection
      super.includes(:forecast_person, :forecast_project, :recurring_assignment_occurrences)
    end
  end

  action_item :materialize_now, only: :edit do
    link_to "Materialize Now",
      materialize_now_admin_recurring_assignment_path(resource),
      method: :post,
      data: { confirm: "Create/refresh Forecast assignments for this rule now?" }
  end

  member_action :materialize_now, method: :post do
    resource.materialize!
    redirect_to edit_admin_recurring_assignment_path(resource), notice: "Materialized."
  rescue => e
    redirect_to edit_admin_recurring_assignment_path(resource), alert: e.message
  end

  action_item :toggle_pause, only: :edit do
    link_to(resource.paused? ? "Resume" : "Pause",
      toggle_pause_admin_recurring_assignment_path(resource), method: :post)
  end

  member_action :toggle_pause, method: :post do
    resource.update!(paused_at: resource.paused? ? nil : Time.current)
    redirect_to edit_admin_recurring_assignment_path(resource),
      notice: resource.paused? ? "Paused." : "Resumed."
  end

  index download_links: false do
    column(:person) { |r| r.forecast_person&.email || "Person ##{r.forecast_person_id}" }
    column(:project) { |r| r.forecast_project&.name || "Project ##{r.forecast_project_id}" }
    column(:hours_per_day) { |r| r.allocation_in_hours }
    column(:weekdays) { |r| r.weekdays.sort.map { |d| Date::ABBR_DAYNAMES[d] }.join(", ") }
    column :starts_on
    column :ends_on
    column(:occurrences) do |r|
      m = r.recurring_assignment_occurrences.count { |o| o.status == "materialized" }
      d = r.recurring_assignment_occurrences.count { |o| o.status == "deleted" }
      "#{m} live / #{d} deleted"
    end
    column(:status) { |r| r.paused? ? status_tag("Paused") : status_tag("Active") }
    actions
  end

  show do
    attributes_table do
      row(:person) { |r| r.forecast_person&.email || "Person ##{r.forecast_person_id}" }
      row(:project) { |r| r.forecast_project&.name || "Project ##{r.forecast_project_id}" }
      row(:hours_per_day) { |r| r.allocation_in_hours }
      row(:weekdays) { |r| r.weekdays.sort.map { |d| Date::ABBR_DAYNAMES[d] }.join(", ") }
      row :starts_on
      row :ends_on
      row :active_on_days_off
      row :notes
      row(:status) { |r| r.paused? ? "Paused" : "Active" }
    end
    panel "Occurrences" do
      table_for resource.recurring_assignment_occurrences.order(occurs_on: :desc) do
        column :occurs_on
        column :status
        column(:forecast_assignment) do |o|
          if o.forecast_assignment_id
            link_to o.forecast_assignment_id,
              "https://forecastapp.com/#{Stacks::Utils.config[:forecast][:account_id]}/schedule/projects/#{o.recurring_assignment.forecast_project_id}/assignments/#{o.forecast_assignment_id}/edit",
              target: "_blank"
          end
        end
      end
    end
  end

  form do |f|
    f.semantic_errors
    f.inputs do
      f.input :forecast_person_id, as: :select,
        collection: ForecastPerson.active.order(:email).map { |p| [p.email, p.forecast_id] },
        prompt: "Choose a person…"
      f.input :forecast_project_id, as: :select,
        collection: ForecastProject.active.map { |p| [p.name, p.forecast_id] }.sort_by(&:first),
        prompt: "Choose a project…"
      f.input :allocation_in_hours, label: "Hours per day", hint: "Stored as seconds/day for Forecast."
      f.input :weekdays, as: :check_boxes, collection: WEEKDAY_CHOICES
      f.input :starts_on, as: :datepicker
      f.input :ends_on, as: :datepicker, hint: "Leave blank for open-ended (never ends). Assignments are only ever created up to today — never in advance; each day's occurrence materializes on/after its date."
      f.input :active_on_days_off
      f.input :notes
    end
    f.actions
  end
end
