class Stacks::DataIntegrityManager
  def initialize
  end

  def notify!
    return if problem_count == 0

    SystemNotification.with({
      subject: "#{problem_count}x Data Integrity Problems discovered.",
      type: :system,
      link: "https://stacks.garden3d.net/admin/data_integrity_explorer",
      error: :data_integrity_problems_present,
      priority: 0
    }).deliver(System.instance)
  end

  def problem_count
    discover_problems.values.map(&:count).reduce(&:+)
  end

  def discover_problems
    Rails.cache.fetch("Stacks::DataIntegrityManager#discover_problems", expires_in: 24.hours) do
      {
        notion_leads: discover_notion_lead_problems,
        forecast_projects: discover_forecast_project_problems,
        forecast_people: discover_forecast_people_problems,
        forecast_assignments: discover_forecast_assignment_problems,
        admin_users: discover_admin_user_problems,
        project_trackers: discover_project_tracker_problems
      }
    end
  end

  def discover_notion_lead_problems
    all_notion_leads = NotionPage.lead.map(&:as_lead)

    notion_leads = all_notion_leads.reduce({}) do |acc, l|
      next acc if l.received_at.present?
      acc[l] = acc[l] || []
      acc[l] = [*acc[l], :no_received_at_timestamp_set]
      acc
    end

    notion_leads = all_notion_leads.reduce(notion_leads) do |acc, l|
      studios = l.studios
      next acc if (studios.present? && studios.any?)
      acc[l] = acc[l] || []
      acc[l] = [*acc[l], :no_studios_set]
      acc
    end

    notion_leads
  end

  def discover_forecast_project_problems
    preloaded_studios = Studio.all
    all_forecast_projects = ForecastProject.includes(:forecast_client).active.reject do |fp|
      fp.is_internal?
    end
    forecast_projects = all_forecast_projects.reduce({}) do |acc, fp|
      next acc unless fp.has_no_explicit_hourly_rate?
      acc[fp] = acc[fp] || []
      acc[fp] = [*acc[fp], :no_explicit_hourly_rate_set]
      acc
    end
    forecast_projects = all_forecast_projects.reduce(forecast_projects) do |acc, fp|
      next acc unless fp.has_multiple_hourly_rates?
      acc[fp] = acc[fp] || []
      acc[fp] = [*acc[fp], :multiple_hourly_rates_set]
      acc
    end
  end

  def discover_forecast_people_problems
    all_forecast_people = ForecastPerson.all
    forecast_people = all_forecast_people.reduce({}) do |acc, fp|
      next acc if fp.archived
      next acc if fp.studios.count == 1
      acc[fp] = acc[fp] || []
      if fp.studios.count == 0
        acc[fp] = [*acc[fp], :no_studio_in_forecast]
      else
        acc[fp] = [*acc[fp], :multiple_studios_in_forecast]
      end
      acc
    end
  end

  def discover_forecast_assignment_problems
    forecast_assignments = ForecastAssignment.includes(:forecast_project).where('end_date > ?', Date.today).reduce({}) do |acc, o|
      next acc if o.forecast_project.is_time_off?
      acc[o] = [*(acc[o] || []), :date_in_future]
      acc
    end

    ForecastAssignment.where('mod(allocation / 60.0, 1) != 0').reduce(forecast_assignments) do |acc, o|
      acc[o] = [*(acc[o] || []), :allocation_needs_rounding_to_nearest_minute]
      acc
    end
  end

  def discover_admin_user_problems
    all_admin_users = AdminUser
      .includes([
        :full_time_periods
      ]).not_ignored

    all_admin_users.reduce({}) do |acc, o|
      acc[o] = [*(acc[o] || []), :no_full_time_periods_set] if o.full_time_periods.empty?
      acc[o] = [*(acc[o] || []), :missing_survey_responses] if o.should_nag_for_survey_responses?

      if o.active?
        # Active Users
        if [Enum::ContributorType::FOUR_DAY, Enum::ContributorType::FIVE_DAY].include?(o.current_contributor_type)
          acc[o] = [*(acc[o] || []), :missing_skill_tree] if o.skill_tree_level_without_salary == "No Reviews Yet"
        end
      else
        # Archived Users
        # TODO: Port over
      end
      acc
    end
  end

  def discover_project_tracker_problems
    all_project_trackers = ProjectTracker
      .includes([
        :project_lead_periods,
        :adhoc_invoice_trackers,
        :forecast_projects
      ])
    all_project_trackers.reduce({}) do |acc, o|
      if o.work_completed_at.nil?
        # Active Projects
        acc[o] = [*(acc[o] || []), :no_team_lead_set] if o.current_team_leads.empty?
        acc[o] = [*(acc[o] || []), :no_account_lead_set] if o.current_account_leads.empty?
        acc[o] = [*(acc[o] || []), :likely_should_mark_as_work_complete?] if o.likely_should_be_marked_as_completed?
      else
        # Completed Projects
        acc[o] = [*(acc[o] || []), :project_capsule_incomplete] if o.work_status == :capsule_pending
      end
      acc
    end
  end
end
