class ProjectTrackerForecastToRunnSyncTask < ApplicationRecord
  belongs_to :project_tracker # TODO: Dependent destroy?
  belongs_to :notification, optional: true, dependent: :destroy

  def run!(runn_instance = Stacks::Runn.new)
    begin
      sync!(runn_instance)
    rescue => e
      notification = Stacks::Notifications.report_exception(e)
      update(settled_at: DateTime.now, notification: notification.record)
    else
      update(settled_at: DateTime.now, notification: nil)
    end
  end

  def success?
    settled_at.present? && notification.nil?
  end

  private

  def runn(runn_instance = Stacks::Runn.new)
    @_runn ||= runn_instance
  end

  def runn_people
    @_runn_people ||= runn.get_people
  end

  def runn_roles
    @_runn_roles ||= runn.get_roles
  end

  def sync!(runn_instance)
    runn(runn_instance)
    # TODO: Ensure we're requesting max page size
    runn_actuals_did_change = false
    forecast_assignments = project_tracker.forecast_assignments.includes(:forecast_person, :forecast_project)

    # 1. Expand our multi-day forecast_assignments as single day Runn.io actuals for easy diffing
    forecast_assigments_as_runn_actuals = forecast_assignments.reduce([]) do |acc, fa|
      runn_role = find_or_create_runn_role_for_forecast_project(fa.forecast_project)
      runn_person = find_or_create_runn_person_for_forecast_person(fa.forecast_person)

      (fa.start_date..fa.end_date).each do |date|
        allocation_in_minutes = (fa.allocation_during_range_in_seconds(date, date, false) / 60.0)

        # Runn rounds to the nearest minute - no seconds are permitted.
        if allocation_in_minutes % 1 != 0
          raise Stacks::Errors::Base.new("A Forecast Assignment for '#{fa.forecast_person.email}' on #{date.to_s} for Forecast Project '#{fa.forecast_project.name}' includes seconds. Runn.io only accepts minutes (and we should never bill our clients in seconds). Please update that Forecast Assignment to the nearest minute.")
        end

        ra = {
          "date" => date.to_s,
          "billableMinutes" => allocation_in_minutes,
          "roleId" => runn_role["id"],
          "personId" => runn_person["id"],
        }

        if existing = acc.find{|era| era == ra}
          # If someone has recorded work to two associated forecast projects,
          # (and they share) the same billable rate, we simply collapse those
          # forecast assignments into a single Runn actual.
          existing["billableMinutes"] += ra["billableMinutes"]
        else
          acc << ra
        end
      end
      acc
    end

    runn_actuals = runn.get_actuals_for_project(project_tracker.runn_project.runn_id)
    # 2. Find Forecast Assignments that don't have a corresponding Runn actual & write them
    forecast_assigments_as_runn_actuals.each do |faara|
      matches = runn_actuals.select do |ra|
        ra["date"] == faara["date"] && ra["roleId"] == faara["roleId"] && ra["personId"] == faara["personId"]
      end

      if matches.empty?
        # Create faara in Runn
        puts "~~~> Found new Forecast Assignment, creating it in Runn."
        runn.create_or_update_actual(
          faara["date"],
          faara["billableMinutes"],
          faara["personId"],
          project_tracker.runn_project.runn_id,
          faara["roleId"],
        )
        runn_actuals_did_change = true
        next
      end

      # Ensure the first match has correct billableMinutes
      keep = matches.shift
      if keep["billableMinutes"] != faara["billableMinutes"]
        puts "~~~> Found existing Runn Actual with incorrect billable minutes, updating it in Runn."
        runn.create_or_update_actual(
          faara["date"],
          faara["billableMinutes"],
          faara["personId"],
          project_tracker.runn_project.runn_id,
          faara["roleId"],
        )
        runn_actuals_did_change = true
      end

      # Zero the remainder, this is theoretically impossible as there should only be max 1 for this tri-union
      matches.each do |ra|
        puts "~~~> Weird...! Found duplicative Runn Actual, zeroing it out in Runn."
        # TODO: Can we delete these yet?
        runn.create_or_update_actual(
          ra["date"],
          0,
          ra["personId"],
          ra["projectId"],
          ra["roleId"]
        )
        runn_actuals_did_change = true
      end
    end

    # 3. Find Runn Actuals that don't have a corresponding Forecast Assignment and zero them
    runn_actuals.each do |ra|
      next if ra["billableMinutes"] == 0

      match = forecast_assigments_as_runn_actuals.find do |faara|
        ra["date"] == faara["date"] && ra["roleId"] == faara["roleId"] && ra["personId"] == faara["personId"]
      end

      if match.nil?
        puts "~~~> Found stale Runn Actual, zeroing it out in Runn."
        # TODO: Can we delete these yet?
        runn.create_or_update_actual(
          ra["date"],
          0,
          ra["personId"],
          ra["projectId"],
          ra["roleId"]
        )
        runn_actuals_did_change = true
      end
    end

    # Reload Runn actuals as they've very likely changed at this point
    if runn_actuals_did_change
      puts "~~~> Runn Actuals did change, reloading fresh from Runn."
      runn_actuals = runn.get_actuals_for_project(project_tracker.runn_project.runn_id)
    end

    calculated_runn_revenue = calculate_runn_revenue(runn_actuals)
    project_tracker_ltv = project_tracker.lifetime_value
    unless calculated_runn_revenue == project_tracker_ltv
      puts "~~~> Failure, even after sync, Runn revenue is different to project_tracker.lifetime_value"
      raise Stacks::Errors::Base.new("Failed Runn sync for Project Tracker (#{project_tracker.name} ID: #{project_tracker.id}), Runn Revenue: #{calculated_runn_revenue}, Project Tracker LTV: #{project_tracker_ltv}")
    end

    puts "~~~> Worked! Stacks lifetime_value and runn_actuals revenue are in sync!"
  end

  def calculate_runn_revenue(runn_actuals)
    runn_actuals.reduce(0) do |acc, ra|
      acc += (runn_roles.find{|rr| rr["id"] == ra["roleId"]}["standardRate"] * (ra["billableMinutes"] / 60.0))
    end
  end

  def find_or_create_runn_person_for_forecast_person(fp)
    runn_person = runn_people.find{|rp| (rp["email"] || "").downcase == (fp.try(:email) || "").downcase}
    return runn_person if runn_person.present?

    runn_person = runn.create_person(
      fp.first_name,
      fp.last_name,
      fp.email,
      runn_roles.find{|rr| rr["name"] == "gardener"}["id"]
    )

    runn_people << runn_person
    runn_person
  end

  def find_or_create_runn_role_for_forecast_project(fp)
    runn_role_name = "$#{sprintf('%.2f', fp.hourly_rate)} p/h"
    existing_role = runn_roles.find do |rr|
      rr["defaultHourCost"] == 0 && rr["standardRate"] == fp.hourly_rate && rr["name"] == runn_role_name
    end
    return existing_role if existing_role.present?

    new_role = runn.create_role(runn_role_name, 0, fp.hourly_rate)
    runn_roles << new_role
    new_role
  end
end
