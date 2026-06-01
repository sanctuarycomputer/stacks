class Stacks::Forecast
  include HTTParty
  base_uri 'api.forecastapp.com'

  def initialize()
    @headers = {
      "Forecast-Account-ID": "#{Stacks::Utils.config[:forecast][:account_id]}",
      "Authorization": "Bearer #{Stacks::Utils.config[:forecast][:token]}",
      "User-Agent": "Stacks Automator"
    }
  end

  # Arbitrary 32-bit int — only purpose is to identify this particular lock.
  SYNC_ALL_ADVISORY_LOCK_KEY = 84_217_295

  def sync_all!
    # Heroku scheduler + daily_tasks both call this; two concurrent runs
    # would deadlock on the ForecastAssignment.delete_all. pg_try_advisory_lock
    # is non-blocking — if another worker already holds it, we skip rather
    # than queue, so a 2nd scheduler tick can't pile up behind a long sync.
    acquired = ActiveRecord::Base.connection.select_value(
      "SELECT pg_try_advisory_lock(#{SYNC_ALL_ADVISORY_LOCK_KEY})"
    )
    unless acquired
      Rails.logger.warn("Stacks::Forecast#sync_all! skipped — another sync is already running")
      return
    end

    begin
      sync_clients!
      sync_people!
      sync_projects!
      # Upsert-then-targeted-delete: walk every month, upsert what we get,
      # and remember which forecast_ids we saw. After the walk, delete only
      # the ids we DIDN'T see — those are assignments removed in Forecast.
      # Replaces the previous `ForecastAssignment.delete_all` + nuke-and-pave
      # which held an AccessExclusiveLock on the table for ~6 minutes and
      # made `/admin` requests time out behind it.
      seen_ids = sync_all_assignments!
      prune_assignments_not_in!(seen_ids)
    ensure
      ActiveRecord::Base.connection.select_value(
        "SELECT pg_advisory_unlock(#{SYNC_ALL_ADVISORY_LOCK_KEY})"
      )
    end
  end

  # Deletes assignments whose forecast_id wasn't seen in the latest sync.
  # Chunked so each transaction holds locks for milliseconds, not seconds,
  # and reads aren't blocked. With ~no stale rows in steady state this is
  # near-instant; only after a Forecast cleanup does any real work happen.
  def prune_assignments_not_in!(seen_ids)
    return if seen_ids.blank?

    ForecastAssignment.where.not(forecast_id: seen_ids).in_batches(of: 1000) do |batch|
      batch.delete_all
    end
  end

  def current_user
    self.class.get("/current_user", headers: @headers)
  end

  def clients
    self.class.get("/clients", headers: @headers)
  end

  def people
    self.class.get("/people", headers: @headers)
  end

  def projects
    self.class.get("/projects", headers: @headers)
  end

  def assignments(start_date, end_date, project_id = nil)
    query = {}
    query["start_date"] = start_date if start_date.present?
    query["end_date"] = end_date if end_date.present?
    query["project_id"] = project_id if project_id.present?

    try = 0
    begin
      self.class.get("/assignments", headers: @headers, query: query)
    rescue Net::OpenTimeout => e
      try += 1
      try <= 5 ? retry : raise
    end
  end

  # Date.new(2001,2,25)
  def milestones(start_date, end_date)
    query = {}
    query["start_date"] = start_date if start_date.present?
    query["end_date"] = end_date if end_date.present?
    self.class.get("/milestones", headers: @headers, query: query)
  end

  def roles
    self.class.get("/roles", headers: @headers)
  end

  private

  def sync_clients!
    data = clients()["clients"].map do |c|
      {
        forecast_id: c["id"],
        name: c["name"],
        harvest_id: c["harvest_id"],
        archived: c["archived"],
        updated_at: c["updated_at"],
        updated_by_id: c["updated_by_id"],
        data: c,
      }
    end
    ForecastClient.upsert_all(data, unique_by: :forecast_id)
  end

  def sync_people!
    data = people()["people"].map do |c|
      {
        forecast_id: c["id"],
        first_name: c["first_name"],
        last_name: c["last_name"],
        email: c["email"],
        archived: c["archived"],
        roles: c["roles"],
        updated_at: c["updated_at"],
        updated_by_id: c["updated_by_id"],
        data: c,
      }
    end
    ForecastPerson.upsert_all(data, unique_by: :forecast_id)
  end

  def sync_projects!
    data = projects()["projects"].map do |c|
      {
        forecast_id: c["id"],
        name: c["name"],
        code: c["code"],
        notes: c["notes"],
        start_date: c["start_date"],
        end_date: c["end_date"],
        harvest_id: c["harvest_id"],
        archived: c["archived"],
        client_id: c["client_id"],
        tags: c["tags"],
        updated_at: c["updated_at"],
        updated_by_id: c["updated_by_id"],
        data: c,
      }
    end
    ForecastProject.upsert_all(data, unique_by: :forecast_id)
  end

  # Returns the array of forecast_ids that were upserted in this call, so
  # sync_all! can collect them across the per-month walk and prune anything
  # not seen.
  def sync_assignments!(start_date = Date.today, end_date = Date.today)
    data = assignments(start_date, end_date)["assignments"].map do |c|
      {
        forecast_id: c["id"],
        start_date: c["start_date"],
        end_date: c["end_date"],
        allocation: c["allocation"],
        notes: c["notes"],
        updated_at: c["updated_at"],
        updated_by_id: c["updated_by_id"],
        project_id: c["project_id"],
        person_id: c["person_id"],
        placeholder_id: c["placeholder_id"],
        repeated_assignment_set_id: c["repeated_assignment_set_id"],
        active_on_days_off: c["active_on_days_off"],
        data: c,
      }
    end
    return [] if data.empty?
    ForecastAssignment.upsert_all(data, unique_by: :forecast_id)
    data.map { |row| row[:forecast_id] }
  end

  def sync_all_assignments!
    time_start = DateTime.parse("1st Jan 2020")
    time_end = 0.seconds.ago
    time = time_start
    seen_ids = []
    while time < time_end
      seen_ids.concat(sync_assignments!(time.beginning_of_month, time.end_of_month))
      time = time.advance(months: 1)
    end
    seen_ids
  end
end
