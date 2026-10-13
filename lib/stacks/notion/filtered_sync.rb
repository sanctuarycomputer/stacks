# Syncs part of a large Notion database into notion_pages, upserting row by
# row. It NEVER deletes a row it did not see (the whole-database sync,
# Stacks::Notion#sync_database, does, which is why these databases must never
# go through it).
#
# EVERY RUN IS FULL unless it is asked to be incremental (:backfill, the
# default): every Problem, and every Observation that has a project and was
# edited in the last 90 days. It has to be. Whether a page is a flag is a
# Notion formula that depends on today's date, and a formula's new result is
# not an edit of the page, so a run that asked only for pages edited since the
# last one would never see a flag lapse. A full run costs one query per 100
# rows: 8 requests a night at about 405 Problems and 236 Observations.
#
# The incremental run (mode: :incremental, by hand only) reads the rows edited
# since the last run. For Observations it stores a new row only when it has a
# project and updates a row only when Stacks already holds it. It is quicker
# after an edit in Notion, and blind to a formula that changed by itself.
#
# Problems: every row is kept, with or without a project, so the problems an
# observation was folded into are always here for the log to read.
#
# A row the full query did not return (trashed, lost its project, last edited
# over 90 days ago) is asked for by id in the recheck, at most RECHECK_LIMIT a
# run. After a full run that is only those rows, since every row the query
# returned was stamped as seen.
class Stacks::Notion::FilteredSync
  FIRST_RUN_WINDOW = 90.days # how far back a full run reads Observations, by last edit
  MIN_WINDOW = 3.days
  OVERLAP = 1.day
  # Where a database that is read whole starts from. Sent in the same filter
  # shape as every other run, so there is one query shape per database.
  EVERYTHING_SINCE = Time.utc(2000, 1, 1)
  MAX_CALLS = 500 # a runaway cursor stops here: 50,000 rows in one run is not real
  RECHECK_LIMIT = 200  # page fetches a run, to notice rows trashed in Notion
  RECHECK_WINDOW = 90.days
  RECHECK_PAUSE = 0.35 # seconds between page fetches: under Notion's three a second
  # Page fetches that may fail in a row before the recheck gives up. Each one
  # has already paid the client's whole retry ladder, so with Notion down a
  # pass that kept going would hold the lock for hours.
  RECHECK_MAX_FAILURES_IN_A_ROW = 5
  ADVISORY_LOCK_KEY = 84_217_297
  SORTS = [{ timestamp: "last_edited_time", direction: "descending" }].freeze
  WRAPPERS = { OBSERVATIONS: Stacks::Notion::Observation, PROBLEMS: Stacks::Notion::Problem }.freeze
  # Whether a row must be filed under a project to be stored.
  REQUIRES_PROJECT = { OBSERVATIONS: true, PROBLEMS: false }.freeze
  # A fallback, off. An incremental run of Observations asks for every row
  # edited in the window. Set this to true to ask only for rows that have a
  # project, as the full run does; a row that lost its project is then noticed
  # by the recheck instead of by the query.
  INCREMENTAL_KEEPS_PROJECT_CLAUSE = false

  # What the wrappers read and the type Notion held for each on 2026-10-12.
  # The preview prints the type found beside these, so a property renamed or
  # retyped in Notion is seen before a real run.
  EXPECTED_PROPERTIES = {
    OBSERVATIONS: {
      "Name" => "title", "Observation" => "rich_text", "Source" => "select", "Source Ref" => "url",
      "Observed At" => "date", "Salience" => "select", "Type" => "select", "Status" => "select",
      "Projects" => "relation", "Problems" => "relation", Stacks::Notion::Observation::VALENCE_PROPERTY => "select",
      Stacks::Notion::Flag::PROPERTY => "formula",
    }.freeze,
    PROBLEMS: {
      "Problem" => "title", "Kind" => "select", "Severity" => "select", "Status" => "select", "Owner" => "people",
      "Owner Name" => "rich_text", "Project" => "relation", "Source Observations" => "relation",
      "Occurrences" => "number", "First Seen" => "date", "Last Seen" => "date", "Proposed Action" => "rich_text",
      Stacks::Notion::Flag::PROPERTY => "formula", Stacks::Notion::Problem::NOT_A_FLAG_PROPERTY => "formula",
    }.freeze,
  }.freeze

  def self.marks
    raw = System.first&.notion_filtered_sync_marks
    raw.is_a?(Hash) ? raw : {}
  end

  # The start time of the last run of this database that reached the end.
  def self.last_synced_at(key)
    Stacks::Notion::Props.parse_time(marks[key.to_s])
  end

  # The one entry point for the rake tasks. Two runs at once would race on the
  # unique notion_id index, so the second does nothing.
  def self.run!(dry_run: false, mode: nil, client: Stacks::Notion.new, now: Time.zone.now)
    conn = ActiveRecord::Base.connection
    return { skipped: "another run holds the lock" } unless conn.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
    begin
      new(client: client, now: now).run_all(dry_run: dry_run, mode: mode)
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
    end
  end

  def initialize(client:, now: Time.zone.now, sleeper: nil)
    @client = client
    @now = now
    @sleeper = sleeper || ->(seconds) { sleep(seconds) }
    @unchanged_ids = []
  end

  # [since, mode]. A full run (:backfill) unless :incremental is asked for.
  # The mark only bounds an incremental run; with none, that reads 3 days.
  def window_for(key, mode: nil)
    floor = REQUIRES_PROJECT.fetch(key) ? @now - FIRST_RUN_WINDOW : EVERYTHING_SINCE
    return [floor, :backfill] unless mode == :incremental
    mark = self.class.last_synced_at(key)
    return [@now - MIN_WINDOW, :incremental] if mark.nil?
    [[[mark - OVERLAP, @now - MIN_WINDOW].min, floor].max, :incremental]
  end

  def sync(key, dry_run: false, mode: nil)
    config = Stacks::Notion::FILTERED_DATABASES.fetch(key)
    since, mode = window_for(key, mode: mode)
    stats = { database: key.to_s, mode: mode.to_s, since: since.utc.iso8601, dry_run: dry_run, calls: 0, seen: 0,
              created: 0, updated: 0, unchanged: 0, skipped_without_project: 0, trashed: 0, truncated_relations: 0 }
    stats[:properties] = {} if dry_run
    cursor = nil
    loop do
      raise Stacks::Notion::Error.new("Notion sync of #{key} did not end after #{MAX_CALLS} calls") if stats[:calls] >= MAX_CALLS
      response = @client.query_database_filtered(config[:id], filter: filter_for(key, since, mode), sorts: SORTS, start_cursor: cursor)
      stats[:calls] += 1
      results = response.is_a?(Hash) && response["results"].is_a?(Array) ? response["results"] : []
      rows = results.select { |r| r.is_a?(Hash) && r["id"].is_a?(String) && r["id"].present? }
      stats[:properties] = property_types(rows.first, key) if dry_run && stats[:properties].empty? && rows.any?
      upsert_all(rows, key, stats, dry_run)
      cursor = response.is_a?(Hash) ? response["next_cursor"] : nil
      break if cursor.blank?
    end
    write_mark(key) unless dry_run
    stats
  end

  def run_all(dry_run: false, mode: nil)
    {
      observations: sync(:OBSERVATIONS, dry_run: dry_run, mode: mode),
      problems: sync(:PROBLEMS, dry_run: dry_run, mode: mode),
      recheck: recheck(dry_run: dry_run),
    }
  end

  # A database query never returns a trashed page, so trash is noticed here:
  # each run asks Notion, by id, about the rows it has gone longest without
  # seeing. Every stored Problem is in scope; Observations for 90 days.
  #
  # One page Notion refuses must not stop the pass: it is counted, sent to
  # the back of the line and skipped. A 200 that does not carry the page asked
  # for is treated the same way. Five failures in a row stop the pass, and so
  # does a pass in which every fetch failed, because that is Notion or the
  # token, not a page.
  def recheck(dry_run: false)
    observations = Stacks::Notion.filtered_parent_id(:OBSERVATIONS)
    problems = Stacks::Notion.filtered_parent_id(:PROBLEMS)
    scope = NotionPage
      .where(notion_parent_type: "database_id", notion_parent_id: [observations, problems])
      .where("notion_pages.synced_at IS NULL OR notion_pages.synced_at < ?", @now)
      .where("notion_pages.notion_parent_id = ? OR notion_pages.occurred_at >= ?", problems, @now - RECHECK_WINDOW)
    stats = { candidates: scope.count, checked: 0, gone: 0, trashed: 0, updated: 0, unchanged: 0, errors: 0 }
    return stats if dry_run

    counts = Hash.new(0)
    @unchanged_ids = []
    failed_ids = []
    last_error = nil
    failures_in_a_row = 0
    scope.order(Arel.sql("notion_pages.synced_at ASC NULLS FIRST, notion_pages.id ASC")).limit(RECHECK_LIMIT).each do |page|
      @sleeper.call(RECHECK_PAUSE) if stats[:checked] > 0
      stats[:checked] += 1
      begin
        result = @client.fetch_page(page.notion_id)
        body = result[:body]
        unless result[:status] == 404 || (body.is_a?(Hash) && body["id"] == page.notion_id)
          raise Stacks::Notion::Error.new("Notion fetch of page #{page.notion_id} answered without that page", status: result[:status])
        end
      rescue Stacks::Notion::Error => e
        stats[:errors] += 1
        failed_ids << page.id
        last_error = e
        failures_in_a_row += 1
        break if failures_in_a_row >= RECHECK_MAX_FAILURES_IN_A_ROW
        next
      end
      failures_in_a_row = 0
      if result[:status] == 404
        # Trusted because this run has just queried the same database: the
        # integration can read it, so a missing page is a deleted page.
        page.destroy
        stats[:gone] += 1
      else
        key = page.notion_parent_id == observations ? :OBSERVATIONS : :PROBLEMS
        upsert(body, key, page, counts, dry_run: false, keep_without_project: true)
      end
    end
    seen_ids = @unchanged_ids + failed_ids
    NotionPage.where(id: seen_ids).update_all(synced_at: @now) if seen_ids.any?
    if failures_in_a_row >= RECHECK_MAX_FAILURES_IN_A_ROW
      raise Stacks::Notion::Error.new(
        "Notion recheck stopped after #{stats[:checked]} page fetches: #{failures_in_a_row} in a row failed, " \
        "so Notion looks unavailable. Last: #{last_error.message}",
        status: last_error.status, code: last_error.code
      )
    end
    if stats[:checked] > 0 && stats[:errors] == stats[:checked]
      raise Stacks::Notion::Error.new(
        "Notion recheck failed: #{stats[:errors]} of #{stats[:checked]} page fetches failed. Last: #{last_error.message}",
        status: last_error.status, code: last_error.code
      )
    end
    stats.merge(trashed: counts[:trashed], updated: counts[:updated], unchanged: counts[:unchanged])
  end

  # Stores one row. `stored` is the NotionPage Stacks holds for it (deleted or
  # not), or nil. Never deletes anything but this row, and only when Notion
  # says this row is in the trash.
  def upsert(r, key, stored, stats, dry_run:, keep_without_project: false)
    config = Stacks::Notion::FILTERED_DATABASES.fetch(key)
    wrapper = WRAPPERS.fetch(key)

    if r["archived"] == true || r["in_trash"] == true
      return if stored.nil? || stored.deleted?
      stats[:trashed] += 1
      stored.destroy unless dry_run
      return
    end

    project_ids = wrapper.project_ids_in(r)
    stats[:truncated_relations] += 1 if Stacks::Notion::Props.relation_truncated?(r, config[:project_property])
    if stored.nil? && project_ids.empty? && REQUIRES_PROJECT.fetch(key) && !keep_without_project
      stats[:skipped_without_project] += 1
      return
    end

    parent_id = Stacks::Notion.filtered_parent_id(key)
    title = Stacks::Notion.normalize_page!(r)
    attrs = { notion_parent_type: "database_id", notion_parent_id: parent_id, data: r, page_title: title,
              project_ids: project_ids, occurred_at: wrapper.occurred_at_in(r) || @now, synced_at: @now }

    if stored.nil?
      stats[:created] += 1
      NotionPage.create!(attrs.merge(notion_id: r["id"])) unless dry_run
    elsif stored.deleted? || stored.project_ids != project_ids || stored.notion_parent_id != parent_id ||
          Hashdiff.diff(r, stored.data).any?
      stats[:updated] += 1
      return if dry_run
      stored.recover! if stored.deleted?
      stored.update!(attrs)
    else
      stats[:unchanged] += 1
      @unchanged_ids << stored.id unless dry_run
    end
  end

  private

  def filter_for(key, since, mode)
    config = Stacks::Notion::FILTERED_DATABASES.fetch(key)
    clauses = []
    if REQUIRES_PROJECT.fetch(key) && (mode == :backfill || INCREMENTAL_KEEPS_PROJECT_CLAUSE)
      clauses << { property: config[:project_property], relation: { is_not_empty: true } }
    end
    clauses << { timestamp: "last_edited_time", last_edited_time: { on_or_after: since.utc.iso8601 } }
    { and: clauses }
  end

  # { property name => the type Notion sent, or "missing" } for one row.
  def property_types(row, key)
    props = row["properties"].is_a?(Hash) ? row["properties"] : {}
    EXPECTED_PROPERTIES.fetch(key).keys.to_h do |name|
      prop = props[name]
      [name, prop.is_a?(Hash) && prop["type"].is_a?(String) ? prop["type"] : "missing"]
    end
  end

  def upsert_all(results, key, stats, dry_run)
    stored = NotionPage.with_deleted.where(notion_id: results.map { |r| r["id"] }).index_by(&:notion_id)
    @unchanged_ids = []
    results.each do |r|
      stats[:seen] += 1
      upsert(r, key, stored[r["id"]], stats, dry_run: dry_run)
    end
    # Unchanged rows are not rewritten; one statement records that they were seen.
    NotionPage.where(id: @unchanged_ids).update_all(synced_at: @now) if @unchanged_ids.any?
  end

  def write_mark(key)
    system = System.first || System.create!(settings: {})
    system.update!(notion_filtered_sync_marks: self.class.marks.merge(key.to_s => @now.utc.iso8601))
  end
end
