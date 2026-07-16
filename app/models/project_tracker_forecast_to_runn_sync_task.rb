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
    raise_if_skip_required!

    runn_actuals_did_change = false
    forecast_assignments = project_tracker.forecast_assignments.includes(:forecast_person, :forecast_project)

    # 1. Expand our multi-day forecast_assignments as single day Runn.io actuals for easy diffing
    forecast_assigments_as_runn_actuals = build_forecast_actuals(forecast_assignments)

    # Real (past/today, billable) hours flowing IS the confirmation signal —
    # confirm a tentative project only once we have actuals to write, never
    # for an all-future or empty assignment set (which would strip a still-
    # pipeline shell out of automated dead-deal cleanup).
    confirm_runn_project_if_needed! if forecast_assigments_as_runn_actuals.any?

    runn_actuals = runn.get_actuals_for_project(project_tracker.runn_project.runn_id)
    project_runn_id = project_tracker.runn_project.runn_id

    # Collect every (create / update / zero) write into a single buffer so we
    # can flush via Runn's bulk endpoint (POST /actuals/bulk, 100 per call)
    # instead of one HTTP round-trip per actual. For PT 27 (The Light Phone)
    # this collapses ~thousands of POSTs into ~tens.
    pending_writes = []

    # Guard: never emit a future-dated write in EITHER direction. A stale
    # future actual already in Runn (pre-fix) has no clamped counterpart and
    # would otherwise be "zeroed" in step 3 — but Runn rejects future writes,
    # re-raising. Drop such rows from the Runn-side sweep; they age out once
    # their date passes.
    runn_actuals = runn_actuals.reject { |ra| Date.parse(ra["date"]) > Time.zone.today }

    # 2. Find Forecast Assignments that don't have a corresponding Runn actual & write them
    forecast_assigments_as_runn_actuals.each do |faara|
      matches = runn_actuals.select do |ra|
        ra["date"] == faara["date"] && ra["roleId"] == faara["roleId"] && ra["personId"] == faara["personId"]
      end

      if matches.empty?
        pending_writes << {
          "date" => faara["date"],
          "billableMinutes" => faara["billableMinutes"],
          "personId" => faara["personId"],
          "projectId" => project_runn_id,
          "roleId" => faara["roleId"],
        }
        next
      end

      keep = matches.shift
      if keep["billableMinutes"] != faara["billableMinutes"]
        pending_writes << {
          "date" => faara["date"],
          "billableMinutes" => faara["billableMinutes"],
          "personId" => faara["personId"],
          "projectId" => project_runn_id,
          "roleId" => faara["roleId"],
        }
      end

      # Zero the remainder — theoretically impossible since Runn enforces
      # one actual per (date, role, person) tuple, but kept as a defensive
      # cleanup for any historical duplicates.
      matches.each do |ra|
        pending_writes << {
          "date" => ra["date"],
          "billableMinutes" => 0,
          "personId" => ra["personId"],
          "projectId" => ra["projectId"],
          "roleId" => ra["roleId"],
        }
      end
    end

    # 3. Find Runn Actuals that don't have a corresponding Forecast Assignment and zero them
    runn_actuals.each do |ra|
      next if ra["billableMinutes"] == 0
      match = forecast_assigments_as_runn_actuals.find do |faara|
        ra["date"] == faara["date"] && ra["roleId"] == faara["roleId"] && ra["personId"] == faara["personId"]
      end
      next if match
      pending_writes << {
        "date" => ra["date"],
        "billableMinutes" => 0,
        "personId" => ra["personId"],
        "projectId" => ra["projectId"],
        "roleId" => ra["roleId"],
      }
    end

    if pending_writes.any?
      puts "~~~> Flushing #{pending_writes.size} actual write(s) to Runn (bulk endpoint, 100/call)."
      begin
        runn.create_or_update_actuals_bulk(pending_writes)
      rescue => e
        raise_skipped_if_runn_project_state_error!(e)
        raise
      end
      runn_actuals_did_change = true
    end

    # Reload Runn actuals as they've very likely changed at this point
    if runn_actuals_did_change
      puts "~~~> Runn Actuals did change, reloading fresh from Runn."
      runn_actuals = runn.get_actuals_for_project(project_tracker.runn_project.runn_id)
    end

    calculated_runn_revenue = calculate_runn_revenue(runn_actuals)
    # Reconcile against the SAME hours we just wrote — i.e. the clamped
    # `forecast_assigments_as_runn_actuals` list, NOT `FA#value_in_usd`.
    # value_in_usd spans the full unclamped start..end range, so for an
    # assignment extending past today it counts future days Runn never
    # received (we never write future-dated actuals), which would make this
    # equality fail every night for exactly the open/ongoing projects this
    # sync targets. Deriving expected revenue from the built list keeps the
    # two sides on identical hours.
    expected_revenue = calculate_runn_revenue(forecast_assigments_as_runn_actuals)
    unless runn_revenue_reconciled?(calculated_runn_revenue, expected_revenue)
      puts "~~~> Failure, even after sync, Runn revenue is different to the actuals we wrote"
      raise Stacks::Errors::Base.new("Failed Runn sync for Project Tracker (#{project_tracker.name} ID: #{project_tracker.id}), Runn Revenue: #{calculated_runn_revenue}, Expected (written) Revenue: #{expected_revenue}")
    end

    puts "~~~> Worked! Stacks lifetime_value and runn_actuals revenue are in sync!"
  end

  def calculate_runn_revenue(runn_actuals)
    runn_actuals.reduce(0) do |acc, ra|
      acc += (runn_roles.find{|rr| rr["id"] == ra["roleId"]}["standardRate"] * (ra["billableMinutes"] / 60.0))
    end
  end

  # Reconcile two revenue sums at whole-cent resolution. calculate_runn_revenue
  # sums `rate * (billableMinutes / 60.0)` in each side's row order; float
  # addition isn't associative, so identical hours summed in Runn's returned
  # order vs our built order can differ in the last binary digit. An exact
  # `==` then fails the reconciliation every night for otherwise-synced
  # projects. Round the DIFFERENCE to cents and require it to be zero: float
  # summation noise (well under a tenth of a cent even at tens-of-thousands
  # of rows) rounds away, while a genuine >=1c discrepancy — the smallest real
  # mis-sync is one billable minute, >= ~$0.20 — survives rounding and fails.
  #
  # Two forms were rejected. A raw `(a - b).abs < 0.01` tolerance is unsafe:
  # `0.01` has no exact binary representation, so a true one-cent gap (e.g.
  # 1.13 - 1.12) computes as 0.00999… < 0.01 and wrongly reconciles. Rounding
  # each side to cents — `(a*100).round == (b*100).round` — fixes that but adds
  # a half-cent rounding seam: for a `.50`-ending rate whose total lands on an
  # x.xx5 boundary, reorder noise can push the two sides to adjacent cents and
  # spuriously raise. Rounding the difference (which is only ever noise, or a
  # real >=1c gap) has no per-side seam and is rate-domain-independent.
  # (PayStub, app/models/pay_stub.rb, uses the looser per-side tolerance form.)
  def runn_revenue_reconciled?(runn_revenue, expected_revenue)
    (runn_revenue - expected_revenue).abs.round(2) == 0
  end

  # If Runn returns a 4xx whose response body signals "this project can't
  # accept actuals right now" — archived, deleted, or non-billable — raise
  # Stacks::Errors::Skipped so the reason is persisted into a Notification
  # row (visible on the project tracker admin page) but Sentry/Twist are
  # suppressed (see Stacks::Notifications.report_exception). The pre-flight
  # `raise_if_skip_required!` catches these when our local runn_project
  # mirror is fresh; this is the defensive catch for when the mirror is
  # stale relative to live Runn state.
  # Runn returns two variants of the "project unreachable" error depending
  # on the endpoint: GET /projects/:id 404s with "Project not found", and
  # POST /actuals/bulk 400s with "Project with id <X> not found." for
  # each offending actual. Both indicate the same condition — our local
  # runn_project mirror points at a Runn project that no longer exists
  # (or never did) — so we treat them identically.
  RUNN_PROJECT_STATE_ERROR_PATTERNS = [
    /Project (?:with id \S+ )?not found/i,
    /non-billable project/i,
  ].freeze

  def raise_skipped_if_runn_project_state_error!(error)
    msg = error.message.to_s
    return unless RUNN_PROJECT_STATE_ERROR_PATTERNS.any? { |re| msg.match?(re) }
    raise Stacks::Errors::Skipped.new(
      "Runn rejected the actuals write (#{msg.slice(0, 160)}). " \
      "Update the Runn project state (un-archive, mark billable) or relink the project tracker to resolve."
    )
  end

  # Runn refuses actuals on tentative projects ("Actuals cannot be on a
  # tentative project."), and nothing else ever flips the flag — the admin
  # "Create Runn project" button deliberately creates is_confirmed:false and
  # nobody finalizes state inside Runn. Real hours flowing IS the
  # confirmation signal: when we are about to sync actuals for a tentative
  # project, confirm it first (in Runn and in the local mirror).
  def confirm_runn_project_if_needed!
    rp = project_tracker.runn_project
    return if rp.nil? || rp.is_confirmed != false
    puts "~~~> Runn project #{rp.runn_id} is tentative but actuals are flowing — confirming it"
    runn.update_project(rp.runn_id, is_confirmed: true)
    rp.update(is_confirmed: true)
  end

  # Raises Stacks::Errors::Skipped when the linked Runn project is in a state
  # where syncing actuals can't possibly succeed — archived, non-billable, or
  # missing from our local mirror. The raise flows through run!'s rescue and
  # persists a Notification with the reason so it surfaces on the project
  # tracker admin page (see app/views/admin/project_trackers/_show.html.erb).
  def raise_if_skip_required!
    rp = project_tracker.runn_project
    reason =
      if rp.nil?
        "no linked Runn project"
      elsif rp.is_archived
        "Runn project is archived"
      elsif rp.pricing_model.to_s == "nb"
        "Runn project is non-billable (pricing_model='nb')"
      end
    return if reason.nil?
    raise Stacks::Errors::Skipped.new("Skipping Runn sync — #{reason}.")
  end

  # Expands multi-day forecast assignments into single-day Runn actuals,
  # collapsing any two entries that share (date, roleId, personId) — even if
  # their billableMinutes differ. This collapse is critical: Runn's API
  # stores ONE actual per (date, role, person), so when a contributor logs
  # hours to two different forecast projects that map to the same Runn role
  # (i.e., share a rate) on the same day, the per-FA writes overwrite each
  # other and Runn ends up reflecting only the last one. Summing here
  # ensures the write to Runn matches the total Stacks lifetime_value.
  def build_forecast_actuals(forecast_assignments)
    forecast_assignments.reduce([]) do |acc, fa|
      # Runn refuses future-dated actuals ("Cannot create actual for future
      # date…"): an open assignment stretching past today only syncs the days
      # that have already happened — the rest sync on future nights. Bind to
      # the org calendar (Time.zone.today), not the process UTC date.
      last_syncable_date = [fa.end_date, Time.zone.today].min
      next acc if fa.start_date > last_syncable_date

      runn_role = find_or_create_runn_role_for_forecast_project(fa.forecast_project)
      runn_person = find_or_create_runn_person_for_forecast_person(fa.forecast_person)

      (fa.start_date..last_syncable_date).each do |date|
        allocation_in_minutes = (fa.allocation_during_range_in_seconds(date, date, false) / 60.0)

        # Runn rounds to the nearest minute - no seconds are permitted.
        if allocation_in_minutes % 1 != 0
          raise Stacks::Errors::Base.new("A Forecast Assignment for '#{fa.forecast_person.email}' on #{date.to_s} for Forecast Project '#{fa.forecast_project.name}' includes seconds. Runn.io only accepts minutes (and we should never bill our clients in seconds). Please update that Forecast Assignment to the nearest minute: #{fa.external_link}")
        end

        ra = {
          "date" => date.to_s,
          "billableMinutes" => allocation_in_minutes,
          "roleId" => runn_role["id"],
          "personId" => runn_person["id"],
        }

        existing = acc.find do |era|
          era["date"] == ra["date"] &&
            era["roleId"] == ra["roleId"] &&
            era["personId"] == ra["personId"]
        end

        if existing
          existing["billableMinutes"] += ra["billableMinutes"]
        else
          acc << ra
        end
      end
      acc
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
