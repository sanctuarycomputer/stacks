class Stacks::Runn
  include HTTParty
  base_uri 'https://api.runn.io'

  # max_retries: 429 backoff count. The cron-side sync keeps the historical
  # 5×61s behavior; request-path callers (MCP tools) MUST pass 0 so a Runn
  # rate-limit can never park a web worker in sleep().
  def initialize(max_retries: 5)
    @max_retries = max_retries
    @headers = {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "Accept-Version": "1.0.0",
      "Authorization": "Bearer #{Stacks::Utils.config[:runn][:api_token]}",
    }
  end

  def handle_response(&block)
    return if block.nil?
    retry_count = 0
    begin
      response = block.call
      raise response.to_s unless response.success?
      response
    rescue => e
      # non-JSON error bodies (HTML 502s etc.) must re-raise the ORIGINAL
      # error, not a JSON::ParserError that masks it
      is_rate_limited = begin
        JSON.parse(e.try(:message).to_s)["statusCode"] == 429
      rescue JSON::ParserError, TypeError, NoMethodError
        false
      end
      raise e unless is_rate_limited
      raise e unless retry_count < @max_retries

      retry_count += 1
      puts "~~~> Sleeping 61.seconds then retrying for the #{retry_count} time"
      sleep(61.seconds)
      retry
    end
  end

  # Arbitrary 32-bit int identifying this lock. Forecast uses 84_217_295.
  SYNC_ALL_ADVISORY_LOCK_KEY = 84_217_296

  # Full mirror refresh: projects, people, roles, assignments. Mirrors the
  # Forecast sync: changed-rows-only upserts, assignments pruned by absence,
  # people/roles never pruned (isArchived is mirrored instead), and a
  # non-blocking advisory lock so the scheduler and daily_tasks can't run
  # two syncs at once. runn_synced_at is stamped only when every table
  # succeeded; a failure part-way leaves the earlier tables refreshed.
  #
  # Returns true when a full sync ran, false when it was skipped because
  # another sync already holds the advisory lock. Callers that report on the
  # run (the rake task) need to tell "skipped" apart from "did the work" —
  # a bare nil could not carry that.
  def sync_all!
    acquired = ActiveRecord::Base.connection.select_value(
      "SELECT pg_try_advisory_lock(#{SYNC_ALL_ADVISORY_LOCK_KEY})"
    )
    unless acquired
      Rails.logger.warn("Stacks::Runn#sync_all! skipped — another sync is already running")
      return false
    end

    begin
      sync_projects!
      sync_people!
      sync_roles!
      seen = sync_assignments!
      prune_assignments_not_in!(seen)
      # System.first, not System.instance: instance is memoized per process and
      # the web workers must see a fresh stamp for the stale-sync pill.
      (System.first || System.create!(settings: {})).update!(runn_synced_at: Time.current)
      true
    ensure
      ActiveRecord::Base.connection.select_value(
        "SELECT pg_advisory_unlock(#{SYNC_ALL_ADVISORY_LOCK_KEY})"
      )
    end
  end

  # Only write rows that are NEW or whose Runn updatedAt moved (same fix the
  # Forecast sync needed — unconditional upsert_all rewrote every row nightly
  # and bloated the table). Returns EVERY seen runn_id so prune-by-absence
  # still treats unchanged rows as present.
  def upsert_changed!(model, rows)
    return [] if rows.empty?

    seen_ids = rows.map { |row| row[:runn_id] }
    stored_updated_at = model.where(runn_id: seen_ids).pluck(:runn_id, :updated_at).to_h
    changed = rows.select do |row|
      prev = stored_updated_at[row[:runn_id]]
      incoming = row[:updated_at]
      prev.nil? || incoming.blank? || prev.to_i != Time.parse(incoming.to_s).to_i
    end
    model.upsert_all(changed, unique_by: :runn_id) if changed.any?
    seen_ids
  end

  # Chunked so each delete holds locks for milliseconds. Blank input is a
  # no-op so an empty fetch can never wipe the mirror.
  def prune_assignments_not_in!(seen_ids)
    return if seen_ids.blank?

    RunnAssignment.where.not(runn_id: seen_ids).in_batches(of: 1000) do |batch|
      batch.delete_all
    end
  end

  def sync_people!(all_people = get_people())
    rows = all_people.map do |c|
      {
        runn_id: c["id"],
        first_name: c["firstName"],
        last_name: c["lastName"],
        email: c["email"],
        is_archived: c["isArchived"] == true,
        created_at: c["createdAt"],
        updated_at: c["updatedAt"],
        data: c,
      }
    end
    upsert_changed!(RunnPerson, rows)
  end

  def sync_roles!(all_roles = get_roles())
    rows = all_roles.map do |c|
      {
        runn_id: c["id"],
        name: c["name"],
        standard_rate: c["standardRate"],
        default_hour_cost: c["defaultHourCost"],
        is_archived: c["isArchived"] == true,
        created_at: c["createdAt"],
        updated_at: c["updatedAt"],
        data: c,
      }
    end
    upsert_changed!(RunnRole, rows)
  end

  def sync_assignments!(all_assignments = get_assignments())
    rows = all_assignments.map do |c|
      {
        runn_id: c["id"],
        person_id: c["personId"],
        project_id: c["projectId"],
        role_id: c["roleId"],
        start_date: c["startDate"],
        end_date: c["endDate"],
        minutes_per_day: c["minutesPerDay"].to_i,
        is_active: c["isActive"] != false,
        is_billable: c["isBillable"] != false,
        is_placeholder: c["isPlaceholder"] == true,
        is_template: c["isTemplate"] == true,
        is_non_working_day: c["isNonWorkingDay"] == true,
        note: c["note"],
        created_at: c["createdAt"],
        updated_at: c["updatedAt"],
        data: c,
      }
    end
    upsert_changed!(RunnAssignment, rows)
  end

  # Lightweight paginated fetch — called once per "Create Runn project"
  # admin action to look up a Runn client by name on demand. No local
  # mirror; the call site matches on name and discards the rest.
  def get_clients
    values = []
    next_cursor = nil
    loop do
      response = handle_response {
        self.class.get("/clients?limit=200&cursor=#{next_cursor}", headers: @headers)
      }
      values = [*values, *response["values"]]
      next_cursor = response["nextCursor"]
      break if next_cursor.nil?
    end
    values
  end

  def get_people
    values = []
    next_cursor = nil
    loop do
      response = handle_response {
        self.class.get("/people?limit=200&cursor=#{next_cursor}", headers: @headers)
      }
      values = [*values, *response["values"]]
      next_cursor = response["nextCursor"]
      break if next_cursor.nil?
    end
    values
  end

  def get_projects
    values = []
    next_cursor = nil
    loop do
      response = handle_response {
        self.class.get("/projects?limit=200&cursor=#{next_cursor}", headers: @headers)
      }
      values = [*values, *response["values"]]
      next_cursor = response["nextCursor"]
      break if next_cursor.nil?
    end
    values
  end

  def get_roles
    values = []
    next_cursor = nil
    loop do
      response = handle_response {
        self.class.get("/roles?limit=200&cursor=#{next_cursor}", headers: @headers)
      }
      values = [*values, *response["values"]]
      next_cursor = response["nextCursor"]
      break if next_cursor.nil?
    end
    values
  end

  def get_actuals_for_project(project_id)
    values = []
    next_cursor = nil
    loop do
      response = handle_response {
        self.class.get("/actuals?limit=500&projectId=#{project_id}&cursor=#{next_cursor}", headers: @headers)
      }
      values = [*values, *response["values"]]
      next_cursor = response["nextCursor"]
      break if next_cursor.nil?
    end
    values
  end

  # Projection-plane reads: planned (forward) assignments. Read-only — backs
  # the get_resourcing_projections MCP tool; the actuals write path above is
  # untouched and nothing here writes to Runn.
  def get_assignments
    values = []
    next_cursor = nil
    loop do
      response = handle_response {
        self.class.get("/assignments?limit=200&cursor=#{CGI.escape(next_cursor.to_s)}", headers: @headers)
      }
      values = [*values, *response["values"]]
      next_cursor = response["nextCursor"]
      break if next_cursor.nil?
    end
    values
  end

  # Leave is only exposed per person (GET /people/:id/time-offs/leave).
  # Runn splits assignments around scheduled leave, so leave that OVERLAPS
  # an assignment means the leave was filed after the allocation — the
  # divergence the resourcing sweep looks for. STAGED: not yet called by
  # get_resourcing_projections (N-per-person live calls are too heavy for the
  # synchronous MCP path) — the sweep currently reads leave from Runn
  # directly; this lands here so a future batched read has one home.
  def get_leave_for_person(person_id)
    person_id = Integer(person_id) # path-injection guard: callers may pass agent-derived input
    values = []
    next_cursor = nil
    loop do
      response = handle_response {
        self.class.get("/people/#{person_id}/time-offs/leave?limit=200&cursor=#{CGI.escape(next_cursor.to_s)}", headers: @headers)
      }
      values = [*values, *response["values"]]
      next_cursor = response["nextCursor"]
      break if next_cursor.nil?
    end
    values
  end

  # --------------------------------------------------------------------------
  # Projection-plane WRITES. Consumed only by the /api/mcp/write tools —
  # planned assignments, tentative shells, placeholders. Runn has no
  # assignment-update endpoint: changes are delete + recreate (the caller's
  # concern). Nothing here touches actuals or rates.
  # --------------------------------------------------------------------------

  def create_assignment(person_id:, project_id:, role_id:, start_date:, end_date:, minutes_per_day:, note: nil, is_billable: nil)
    body = {
      "personId" => Integer(person_id),
      "projectId" => Integer(project_id),
      "roleId" => Integer(role_id),
      "startDate" => start_date,
      "endDate" => end_date,
      "minutesPerDay" => Integer(minutes_per_day),
      "note" => note,
      "isBillable" => is_billable,
    }.compact
    handle_response {
      self.class.post("/assignments", { body: JSON.dump(body), headers: @headers })
    }.parsed_response
  end

  def delete_assignment(assignment_id)
    assignment_id = Integer(assignment_id)
    handle_response {
      self.class.delete("/assignments/#{assignment_id}", headers: @headers)
    }.parsed_response
  end

  def update_project(project_id, is_archived: nil, is_confirmed: nil)
    project_id = Integer(project_id)
    raise ArgumentError, "update_project: no fields to update" if is_archived.nil? && is_confirmed.nil?
    body = { "isArchived" => is_archived, "isConfirmed" => is_confirmed }.compact
    handle_response {
      self.class.patch("/projects/#{project_id}", { body: JSON.dump(body), headers: @headers })
    }.parsed_response
  end

  # Placeholder "person" (names are Runn-generated). Runn garbage-collects
  # placeholders with no assignment within ~24h — callers must assign fast.
  def create_placeholder(role_id:)
    handle_response {
      self.class.post("/placeholders", { body: JSON.dump({ "roleId" => Integer(role_id) }), headers: @headers })
    }.parsed_response
  end

  def sync_projects!(all_projects = get_projects())
    data = all_projects.map do |c|
      {
        runn_id: c["id"],
        name: c["name"],
        is_template: c["isTemplate"],
        is_archived: c["isArchived"],
        is_confirmed: c["isConfirmed"],
        pricing_model: c["pricingModel"],
        rate_type: c["rateType"],
        budget: c["budget"],
        expenses_budget: c["expensesBudget"],
        # Stacks doesn't need to know about these for now,
        # but we can backfill in the future if necessary
        #runn_team_id: c["teamId"],
        #runn_client_id: c["clientId"],
        #runn_rate_card_id: c["rateCardId"],
        created_at: c["createdAt"],
        updated_at: c["updatedAt"],
        data: c,
      }
    end
    upsert_changed!(RunnProject, data)
  end

  def create_or_update_actual(date, billable_minutes, runn_person_id, runn_project_id, runn_role_id)
    handle_response {
      self.class.post("/actuals", {
        body: JSON.dump({
          "date": date,
          "billableMinutes": billable_minutes,
          "nonbillableMinutes": 0,
          "personId": runn_person_id,
          "projectId": runn_project_id,
          "roleId": runn_role_id
        }),
        headers: @headers
      })
    }
  end

  # Bulk create-or-update for actuals. Runn caps each request at 100, so the
  # caller can pass any-size array and we chunk transparently. Each entry
  # must include date / billableMinutes / personId / projectId / roleId
  # (nonbillableMinutes defaults to 0). Same upsert semantics as the single
  # endpoint: each (date, person, project, role, workstream) tuple is
  # overwritten by the supplied minutes, so callers must dedupe by that
  # tuple before submitting or only the last value sticks.
  BULK_ACTUALS_CHUNK_SIZE = 100

  def create_or_update_actuals_bulk(actuals)
    return if actuals.empty?
    actuals.each_slice(BULK_ACTUALS_CHUNK_SIZE) do |chunk|
      payload = chunk.map do |a|
        {
          "date" => a["date"] || a[:date],
          "billableMinutes" => a["billableMinutes"] || a[:billableMinutes],
          "nonbillableMinutes" => a["nonbillableMinutes"] || a[:nonbillableMinutes] || 0,
          "personId" => a["personId"] || a[:personId],
          "projectId" => a["projectId"] || a[:projectId],
          "roleId" => a["roleId"] || a[:roleId],
        }
      end
      handle_response {
        self.class.post("/actuals/bulk", {
          body: JSON.dump({ "actuals" => payload }),
          headers: @headers,
        })
      }
    end
  end

  # Create a new project in Runn under a given client. Used by the "Create
  # Runn project" admin button on ProjectTracker so admins don't have to
  # bounce into Runn to set this up manually.
  #
  # `name` — display name (typically the ProjectTracker name).
  # `runn_client_id` — the Runn clientId the project lives under. The call
  #   site resolves this by matching forecast_client.name against
  #   get_clients live (no local mirror).
  # `pricing_model` — "tm" (time and materials, billable), "fp" (fixed
  #   price), or "nb" (non-billable). Defaults to "tm" since that's what
  #   the sync expects.
  # `is_confirmed` — whether the project is confirmed in Runn's pipeline
  #   model. Defaults false so admins finalize state in Runn.
  def create_project(name, runn_client_id, pricing_model: "tm", is_confirmed: false)
    handle_response {
      self.class.post("/projects/", {
        body: JSON.dump({
          "name": name,
          "clientId": runn_client_id,
          "pricingModel": pricing_model,
          "isConfirmed": is_confirmed,
          "isTemplate": false,
        }),
        headers: @headers,
      })
    }.parsed_response
  end

  def create_role(name, default_hour_cost, standard_rate)
     handle_response {
        self.class.post("/roles/", {
        body: JSON.dump({
          "name": name,
          "defaultHourCost": default_hour_cost,
          "standardRate": standard_rate
        }),
        headers: @headers
      })
    }
  end

  def create_person(first_name, last_name, email, role_id)
    handle_response {
      self.class.post("/people/", {
        body: JSON.dump({
          "firstName": first_name,
          "lastName": last_name,
          "email": email,
          "roleId": role_id
        }),
        headers: @headers
      })
    }
  end
end