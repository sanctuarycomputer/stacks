# TODO: Sync full_time_periods to Runn Contracts

class Stacks::ForecastToRunnSyncer
  def initialize(project_tracker)
    raise "no_runn_project" if project_tracker.runn_project.nil?
    @project_tracker = project_tracker

    @runn = Stacks::Runn.new
    @runn_people = @runn.get_people
    @runn_roles = @runn.get_roles
    @runn_actuals = @runn.get_actuals_for_project(@project_tracker.runn_project.runn_id)
    @latest_known_runn_recorded_date = @runn_actuals
      .select{|ra| ra["billableMinutes"] > 0}
      .map{|ra| Date.parse(ra["date"])}
      .max
  end

  def self.sync_all!
    ProjectTracker.where.not(runn_project: nil).each do |pt|
      puts "~~~> Will sync '#{pt.name}' Forecast Assignments to '#{pt.runn_project.name}' Actuals"
      Stacks::ForecastToRunnSyncer.new(pt)
      puts "~~~> Did sync '#{pt.name}' Forecast Assignments to '#{pt.runn_project.name}' Actuals"
    end
  end

  def sync!
    # 1. We attempt to "append only" our assignments starting from the
    # last known date in our actuals list
    if @latest_known_runn_recorded_date.present?
      puts "~~~> Attempting to append-only new Forecast Assignments"
      @project_tracker.forecast_projects.each do |fp|
        runn_role = find_or_create_runn_role_for_forecast_project(fp)

        new_forecast_assignments = @latest_known_runn_recorded_date ? (fp.forecast_assignments
          .where("end_date >= ? AND start_date <= ?", @latest_known_runn_recorded_date, Date.today)
          .includes(:forecast_person)
        ) : @project_tracker.start_date

        new_forecast_assignments.each do |fa|
          runn_person = @runn_people.find{|rp| rp["email"].downcase == (fa.forecast_person.try(:email) || "").downcase}
          unless runn_person.present?
            puts "~~~> Could not find a Runn person for Forecast Person with ID: #{fa.forecast_person.id}"
            next
          end
          sync_forecast_assignment_to_runn_actual!(fa, runn_person, runn_role)
        end
      end
    end

    # 2. Now, we check that Runn & Forecast thing the project revenue
    # is the same, which would mean that nothing meaningful has likely
    # changed in Forecast, and we can should short circuit.

    # 2.1. Reload Runn actuals as we've likely made more at this point
    @runn_actuals = @runn.get_actuals_for_project(@project_tracker.runn_project.runn_id)
    return if calculate_runn_revenue == @project_tracker.lifetime_value
    puts "~~~> Runn revenue is out of sync with our @project_tracker.lifetime_value, doing a full reset"

    # 3.0 Here, we found that the "append only" approach meant that
    # our Forecast project revenue is different to Runn's revenue
    # calculation, so we reset_all_actuals! (Runn does not support)
    # DELETE operations on an actual, so we can rebuild the actuals
    # from the ground up.
    reset_all_actuals!
    @project_tracker.forecast_projects.each do |fp|
      runn_role = find_or_create_runn_role_for_forecast_project(fp)
      all_forecast_assignments = fp.forecast_assignments.includes(:forecast_person)
      all_forecast_assignments.each do |fa|
        runn_person = @runn_people.find{|rp| rp["email"].downcase == (fa.forecast_person.try(:email) || "").downcase}
        unless runn_person.present?
          puts "~~~> Could not find a Runn person for Forecast Person with ID: #{fa.forecast_person.id}"
          next
        end
        sync_forecast_assignment_to_runn_actual!(fa, runn_person, runn_role)
      end
    end

    # 4.0 Let's double check we're now in sync from a revenue perspective.
    # if not, something is seriously wrong with this code, so let's send
    # a system notification to check in on that.
    @runn_actuals = @runn.get_actuals_for_project(@project_tracker.runn_project.runn_id)
    unless @project_tracker.lifetime_value == calculate_runn_revenue
      puts "~~~> Runn revenue STILL out of sync with our @project_tracker.lifetime_value, sending system notification!"
      SystemNotification.with({
        subject: @project_tracker,
        type: :project_tracker,
        link: Rails.application.routes.url_helpers.admin_project_tracker_url(@project_tracker.id, host: "https://stacks.garden3d.net"),
        error: :runn_revenue_out_of_sync,
        priority: 1
      }).deliver(System.instance)
    end
  end

  private

  def calculate_runn_revenue
    @runn_actuals.reduce(0) do |acc, ra|
      acc += (@runn_roles.find{|rr| rr["id"] == ra["roleId"]}["standardRate"] * (ra["billableMinutes"] / 60.0))
    end
  end

  def reset_all_actuals!
    @runn_actuals.each do |ra|
      actual = @runn.create_or_update_actual(
        ra["date"],
        0,
        ra["personId"],
        ra["projectId"],
        ra["roleId"]
      )
    end
  end

  def find_or_create_runn_role_for_forecast_project(fp)
    runn_role_name = "$#{sprintf('%.2f', fp.hourly_rate)} p/h"
    existing_role = @runn_roles.find do |rr|
      rr["defaultHourCost"] == 0 && rr["standardRate"] == fp.hourly_rate && rr["name"] == runn_role_name
    end
    return existing_role if existing_role.present?
    new_role = @runn.create_role(runn_role_name, 0, fp.hourly_rate)
    @runn_roles << new_role
    new_role
  end

  def sync_forecast_assignment_to_runn_actual!(fa, runn_person, runn_role)
    (fa.start_date..fa.end_date).each do |date|
      allocation_in_minutes = (fa.allocation_during_range_in_seconds(date, date, false) / 60)
      actual = @runn.create_or_update_actual(
        date,
        allocation_in_minutes,
        runn_person["id"],
        @project_tracker.runn_project.runn_id,
        runn_role["id"]
      )
    end
  end
end
