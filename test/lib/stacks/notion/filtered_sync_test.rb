require 'test_helper'

class StacksNotionFilteredSyncTest < ActiveSupport::TestCase
  include NotionLogFixtures

  OBS = Stacks::Notion::FILTERED_DATABASES[:OBSERVATIONS][:id]
  PROB = Stacks::Notion::FILTERED_DATABASES[:PROBLEMS][:id]
  NOW = Time.utc(2026, 10, 13, 5, 0, 0)

  setup do
    System.delete_all
    System.create!(settings: {})
  end

  # The recheck pauses between page fetches; no test waits for it.
  def sync_with(client, now: NOW)
    Stacks::Notion::FilteredSync.new(client: client, now: now, sleeper: ->(_seconds) {})
  end

  def mark!(key, time)
    System.first.update!(notion_filtered_sync_marks: Stacks::Notion::FilteredSync.marks.merge(key.to_s => time.utc.iso8601))
  end

  test "the first run asks for 90 days of rows that have a project, newest edit first" do
    client = FakeNotion.new
    stats = sync_with(client).sync(:OBSERVATIONS)
    q = client.queries.first
    assert_equal OBS, q[:database_id]
    assert_equal({ and: [{ property: "Projects", relation: { is_not_empty: true } },
                         { timestamp: "last_edited_time", last_edited_time: { on_or_after: "2026-07-15T05:00:00Z" } }] }, q[:filter])
    assert_equal [{ timestamp: "last_edited_time", direction: "descending" }], q[:sorts]
    assert_equal "backfill", stats[:mode]
  end

  # The Problems database is small and an observation's problems must always
  # be in the table for the escalated check, so every Problem is synced.
  test "Problems are asked for whole: no project clause and no 90-day bound" do
    client = FakeNotion.new
    stats = sync_with(client).sync(:PROBLEMS)
    assert_equal PROB, client.queries.first[:database_id]
    assert_equal({ and: [{ timestamp: "last_edited_time", last_edited_time: { on_or_after: "2000-01-01T00:00:00Z" } }] },
                 client.queries.first[:filter])
    assert_equal "backfill", stats[:mode]
  end

  test "a problem with no project is stored, under no tracker" do
    row = problem_data(name: "Timeline slipping", project_ids: [])
    stats = sync_with(FakeNotion.new(pages: { PROB => [[row]] })).sync(:PROBLEMS)
    assert_equal({ created: 1, skipped_without_project: 0 }, stats.slice(:created, :skipped_without_project))
    page = NotionPage.problems.find_by!(notion_id: row["id"])
    assert_equal [], page.project_ids
    assert_equal "Timeline slipping", page.as_problem.title
  end

  test "a later run of Problems reads from the last run less a day, however long ago, and still stores a new one" do
    mark!(:PROBLEMS, NOW - 200.days)
    row = problem_data(project_ids: [])
    client = FakeNotion.new(pages: { PROB => [[row]] })
    stats = sync_with(client).sync(:PROBLEMS)
    assert_equal({ and: [{ timestamp: "last_edited_time", last_edited_time: { on_or_after: "2026-03-26T05:00:00Z" } }] },
                 client.queries.first[:filter])
    assert_equal "incremental", stats[:mode]
    assert_equal 1, NotionPage.problems.count
  end

  test "one constant puts the project clause back on later runs of Observations" do
    mark!(:OBSERVATIONS, NOW - 6.hours)
    Stacks::Notion::FilteredSync.stub_const(:INCREMENTAL_KEEPS_PROJECT_CLAUSE, true) do
      client = FakeNotion.new
      sync_with(client).sync(:OBSERVATIONS)
      assert_equal({ and: [{ property: "Projects", relation: { is_not_empty: true } },
                           { timestamp: "last_edited_time", last_edited_time: { on_or_after: "2026-10-10T05:00:00Z" } }] },
                   client.queries.first[:filter])
      problems = FakeNotion.new
      sync_with(problems).sync(:PROBLEMS)
      assert_equal 1, problems.queries.first[:filter][:and].size, "Problems never carry it"
    end
  end

  test "a later run asks for every row edited since the last run less a day, and never under 3 days" do
    { 6.hours => "2026-10-10T05:00:00Z", 10.days => "2026-10-02T05:00:00Z", 200.days => "2026-07-15T05:00:00Z" }.each do |ago, since|
      mark!(:OBSERVATIONS, NOW - ago)
      client = FakeNotion.new
      stats = sync_with(client).sync(:OBSERVATIONS)
      assert_equal({ and: [{ timestamp: "last_edited_time", last_edited_time: { on_or_after: since } }] },
                   client.queries.first[:filter], "last run #{ago.inspect} ago")
      assert_equal "incremental", stats[:mode]
    end
  end

  test "rows land in notion_pages with their projects, their date and the queried database as parent" do
    at = Time.utc(2026, 10, 1, 12)
    row = observation_data(name: "Client unhappy", observed_at: at, project_ids: %w[p1 p2])
    row["parent"] = { "type" => "database_id", "database_id" => "some-other-spelling" }
    row["icon"] = { "type" => "emoji", "emoji" => "👀" }
    stats = sync_with(FakeNotion.new(pages: { OBS => [[row]] })).sync(:OBSERVATIONS)
    page = NotionPage.find_by!(notion_id: row["id"])
    assert_equal "database_id", page.notion_parent_type
    assert_equal Stacks::Notion.filtered_parent_id(:OBSERVATIONS), page.notion_parent_id
    assert_equal "Client unhappy", page.page_title
    assert_equal %w[p1 p2], page.project_ids
    assert_equal at, page.occurred_at
    assert_equal NOW, page.synced_at
    assert_not page.data.key?("icon"), "the icon is stripped as the whole-database sync strips it"
    assert_equal 1, stats[:created]
    assert_equal 1, stats[:seen]
    assert_equal [page.id], NotionPage.observations.pluck(:id)
  end

  test "it follows the cursor to the last page" do
    a, b, c = Array.new(3) { observation_data(project_ids: %w[p1]) }
    client = FakeNotion.new(pages: { OBS => [[a, b], [c]] })
    stats = sync_with(client).sync(:OBSERVATIONS)
    assert_equal [nil, "1"], client.queries.map { |q| q[:start_cursor] }
    assert_equal 2, stats[:calls]
    assert_equal 3, NotionPage.observations.count
  end

  test "it never deletes a row it did not see" do
    unseen = observation!(project_ids: %w[p1])
    lead = NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                              notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]), data: {})
    seen = observation_data(project_ids: %w[p1])
    sync_with(FakeNotion.new(pages: { OBS => [[seen]] })).sync(:OBSERVATIONS)
    assert NotionPage.exists?(unseen.id), "an unseen observation is kept"
    assert NotionPage.exists?(lead.id), "another database's row is untouched"
    assert_nil unseen.reload.deleted_at
    assert_equal 2, NotionPage.observations.count
  end

  test "a second identical run rewrites nothing and only moves synced_at" do
    row = observation_data(project_ids: %w[p1])
    sync_with(FakeNotion.new(pages: { OBS => [[row]] })).sync(:OBSERVATIONS)
    later = NOW + 1.day
    stats = sync_with(FakeNotion.new(pages: { OBS => [[row]] }), now: later).sync(:OBSERVATIONS)
    assert_equal 0, stats[:created]
    assert_equal 0, stats[:updated]
    assert_equal 1, stats[:unchanged]
    assert_equal later, NotionPage.find_by!(notion_id: row["id"]).synced_at
  end

  test "a row dismissed in Notion is updated in place" do
    id = SecureRandom.uuid
    sync_with(FakeNotion.new(pages: { OBS => [[observation_data(id: id, status: "New", project_ids: %w[p1])]] })).sync(:OBSERVATIONS)
    stats = sync_with(FakeNotion.new(pages: { OBS => [[observation_data(id: id, status: "Dismissed", project_ids: %w[p1])]] }),
                      now: NOW + 1.day).sync(:OBSERVATIONS)
    assert_equal 1, stats[:updated]
    assert NotionPage.find_by!(notion_id: id).as_observation.dismissed?
    assert_equal 1, NotionPage.observations.count
  end

  test "a stored row that lost its project is kept and leaves every tracker" do
    tracker, project_id = log_tracker!
    stored = observation!(project_ids: [project_id])
    mark!(:OBSERVATIONS, NOW - 1.day)
    edited = observation_data(id: stored.notion_id, project_ids: [])
    stats = sync_with(FakeNotion.new(pages: { OBS => [[edited]] })).sync(:OBSERVATIONS)
    assert_equal 1, stats[:updated]
    assert_equal [], stored.reload.project_ids
    assert_nil stored.deleted_at
    assert_empty NotionPage.where("project_ids && ARRAY[?]::varchar[]", tracker.notion_project_ids)
  end

  test "a row with no project that Stacks does not hold is not stored" do
    mark!(:OBSERVATIONS, NOW - 1.day)
    stats = sync_with(FakeNotion.new(pages: { OBS => [[observation_data(project_ids: [])]] })).sync(:OBSERVATIONS)
    assert_equal 1, stats[:skipped_without_project]
    assert_equal 0, NotionPage.observations.count
  end

  test "a row trashed in Stacks and then seen again comes back" do
    stored = observation!(project_ids: %w[p1])
    stored.destroy
    assert stored.reload.deleted?
    sync_with(FakeNotion.new(pages: { OBS => [[observation_data(id: stored.notion_id, project_ids: %w[p1])]] })).sync(:OBSERVATIONS)
    assert_not NotionPage.with_deleted.find(stored.id).deleted?
  end

  test "a row the query returns as archived is soft-deleted, and never created" do
    stored = observation!(project_ids: %w[p1])
    rows = [observation_data(id: stored.notion_id, project_ids: %w[p1], archived: true),
            observation_data(project_ids: %w[p1], archived: true)]
    stats = sync_with(FakeNotion.new(pages: { OBS => [rows] })).sync(:OBSERVATIONS)
    assert_equal 1, stats[:trashed]
    assert NotionPage.with_deleted.find(stored.id).deleted?
    assert_equal 0, NotionPage.observations.count
  end

  test "a relation Notion cut at 25 is stored as sent and counted" do
    row = observation_data(project_ids: %w[p1])
    row["properties"]["Projects"]["has_more"] = true
    stats = sync_with(FakeNotion.new(pages: { OBS => [[row]] })).sync(:OBSERVATIONS)
    assert_equal 1, stats[:truncated_relations]
    assert_equal %w[p1], NotionPage.find_by!(notion_id: row["id"]).project_ids
  end

  test "results that are not pages with an id are skipped" do
    rows = [nil, "x", {}, { "id" => nil }, observation_data(project_ids: %w[p1])]
    stats = sync_with(FakeNotion.new(pages: { OBS => [rows] })).sync(:OBSERVATIONS)
    assert_equal 1, stats[:seen]
    assert_equal 1, NotionPage.observations.count
  end

  test "the mark is the run's start time, written after the last page" do
    sync_with(FakeNotion.new(pages: { OBS => [[observation_data(project_ids: %w[p1])]] })).sync(:OBSERVATIONS)
    assert_equal NOW, Stacks::Notion::FilteredSync.last_synced_at(:OBSERVATIONS)
    assert_nil Stacks::Notion::FilteredSync.last_synced_at(:PROBLEMS), "each database has its own mark"
  end

  test "a run that fails on a later page keeps what it stored and writes no mark" do
    a = observation_data(project_ids: %w[p1])
    client = FakeNotion.new(pages: { OBS => [[a], [observation_data(project_ids: %w[p1])]] }, fail_on_page: 1)
    assert_raises(Stacks::Notion::Error) { sync_with(client).sync(:OBSERVATIONS) }
    assert NotionPage.exists?(notion_id: a["id"])
    assert_nil Stacks::Notion::FilteredSync.last_synced_at(:OBSERVATIONS)
  end

  test "a dry run writes nothing and counts what it would do" do
    stored = observation!(status: "New", project_ids: %w[p1], synced_at: NOW - 2.days)
    rows = [observation_data(id: stored.notion_id, status: "Dismissed", project_ids: %w[p1]),
            observation_data(project_ids: %w[p1]), observation_data(project_ids: %w[p2])]
    stats = sync_with(FakeNotion.new(pages: { OBS => [rows] })).sync(:OBSERVATIONS, dry_run: true)
    assert_equal({ created: 2, updated: 1, seen: 3 }, stats.slice(:created, :updated, :seen))
    assert stats[:dry_run]
    assert_equal 1, NotionPage.observations.count
    assert_equal "New", stored.reload.as_observation.status
    assert_equal NOW - 2.days, stored.synced_at
    assert_nil Stacks::Notion::FilteredSync.last_synced_at(:OBSERVATIONS)
  end

  test "a dry run reports the type of each property the log reads, from the first row" do
    row = observation_data(project_ids: %w[p1], valence_property: false)
    row["properties"]["Status"] = { "type" => "status", "status" => { "name" => "New" } }
    stats = sync_with(FakeNotion.new(pages: { OBS => [[row, observation_data(project_ids: %w[p1])]] })).sync(:OBSERVATIONS, dry_run: true)
    assert_equal "title", stats[:properties]["Name"]
    assert_equal "relation", stats[:properties]["Projects"]
    assert_equal "status", stats[:properties]["Status"]
    assert_equal "missing", stats[:properties]["Valence"]
    assert_equal Stacks::Notion::FilteredSync::EXPECTED_PROPERTIES[:OBSERVATIONS].keys.sort, stats[:properties].keys.sort
    assert_equal({}, sync_with(FakeNotion.new).sync(:PROBLEMS, dry_run: true)[:properties], "no row, nothing to report")
    assert_not sync_with(FakeNotion.new(pages: { OBS => [[row]] })).sync(:OBSERVATIONS).key?(:properties)
  end

  test "a dry run can be made in the later runs' shape before there is a mark" do
    client = FakeNotion.new
    stats = sync_with(client).sync(:OBSERVATIONS, dry_run: true, mode: :incremental)
    assert_equal({ and: [{ timestamp: "last_edited_time", last_edited_time: { on_or_after: "2026-10-10T05:00:00Z" } }] },
                 client.queries.first[:filter])
    assert_equal "incremental", stats[:mode]
  end

  test "a mark that cannot be read counts as no mark" do
    System.first.update!(notion_filtered_sync_marks: { "OBSERVATIONS" => "garbage" })
    assert_nil Stacks::Notion::FilteredSync.last_synced_at(:OBSERVATIONS)
    assert_equal :backfill, sync_with(FakeNotion.new).window_for(:OBSERVATIONS).last
  end

  test "recheck soft-deletes a row Notion has trashed, and one Notion no longer has" do
    trashed = observation!(project_ids: %w[p1], synced_at: NOW - 3.days)
    gone = problem!(project_ids: %w[p1], synced_at: NOW - 2.days)
    live = observation!(project_ids: %w[p1], synced_at: NOW - 1.day)
    client = FakeNotion.new(by_id: {
      trashed.notion_id => observation_data(id: trashed.notion_id, project_ids: %w[p1], archived: true),
      live.notion_id => live.data,
    })
    stats = sync_with(client).recheck
    assert_equal [trashed.notion_id, gone.notion_id, live.notion_id], client.fetched, "least recently checked first"
    assert_equal({ candidates: 3, checked: 3, gone: 1, trashed: 1, updated: 0, unchanged: 1, errors: 0 }, stats)
    assert NotionPage.with_deleted.find(trashed.id).deleted?
    assert NotionPage.with_deleted.find(gone.id).deleted?
    assert_nil live.reload.deleted_at
    assert_equal NOW, live.synced_at
  end

  test "recheck picks up a change the queries missed, and a row that lost its project stays stored" do
    stored = observation!(status: "New", project_ids: %w[p1], synced_at: NOW - 1.day)
    client = FakeNotion.new(by_id: { stored.notion_id => observation_data(id: stored.notion_id, status: "Dismissed", project_ids: []) })
    stats = sync_with(client).recheck
    assert_equal 1, stats[:updated]
    assert_equal [], stored.reload.project_ids
    assert stored.as_observation.dismissed?
    assert_nil stored.deleted_at
  end

  test "recheck leaves alone a row this run already saw, an old observation, and other databases" do
    observation!(project_ids: %w[p1], synced_at: NOW)
    observation!(project_ids: %w[p1], synced_at: NOW - 5.days, observed_at: NOW - 91.days)
    NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                       notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]), data: {})
    old_problem = problem!(project_ids: %w[p1], synced_at: NOW - 5.days, last_seen: NOW - 200.days)
    client = FakeNotion.new(by_id: { old_problem.notion_id => old_problem.data })
    sync_with(client).recheck
    assert_equal [old_problem.notion_id], client.fetched, "every stored problem is rechecked, whatever its age"
  end

  test "recheck takes at most 200 rows" do
    rows = Array.new(203) { |i| observation!(project_ids: %w[p1], synced_at: NOW - (i + 1).hours) }
    client = FakeNotion.new(by_id: rows.to_h { |r| [r.notion_id, r.data] })
    stats = sync_with(client).recheck
    assert_equal 200, client.fetched.size
    assert_equal 203, stats[:candidates]
    assert_equal 200, stats[:checked]
    assert_equal rows.last.notion_id, client.fetched.first
  end

  test "run! does nothing while another run holds the lock" do
    other = ActiveRecord::Base.connection_pool.checkout
    begin
      other.execute("SELECT pg_advisory_lock(#{Stacks::Notion::FilteredSync::ADVISORY_LOCK_KEY})")
      client = FakeNotion.new
      out = Stacks::Notion::FilteredSync.run!(client: client, now: NOW)
      assert_equal({ skipped: "another run holds the lock" }, out)
      assert_empty client.queries
    ensure
      other.execute("SELECT pg_advisory_unlock(#{Stacks::Notion::FilteredSync::ADVISORY_LOCK_KEY})")
      ActiveRecord::Base.connection_pool.checkin(other)
    end
  end

  test "run! releases the lock when the sync raises" do
    client = FakeNotion.new(fail_on_page: 0)
    assert_raises(Stacks::Notion::Error) { Stacks::Notion::FilteredSync.run!(client: client, now: NOW) }
    assert_not Stacks::Notion::FilteredSync.run!(client: FakeNotion.new, now: NOW).key?(:skipped),
               "a run after a failed one is not skipped"
  end

  test "recheck pauses between page fetches, not before the first" do
    rows = Array.new(3) { |i| observation!(project_ids: %w[p1], synced_at: NOW - (i + 1).hours) }
    slept = []
    sync = Stacks::Notion::FilteredSync.new(client: FakeNotion.new(by_id: rows.to_h { |r| [r.notion_id, r.data] }),
                                            now: NOW, sleeper: ->(seconds) { slept << seconds })
    sync.recheck
    assert_equal [0.35, 0.35], slept
  end

  test "one page Notion refuses does not stop the recheck: it is counted and goes to the back of the line" do
    bad = observation!(project_ids: %w[p1], synced_at: NOW - 3.days)
    trashed = problem!(project_ids: %w[p1], synced_at: NOW - 2.days)
    live = observation!(project_ids: %w[p1], synced_at: NOW - 1.day)
    client = FakeNotion.new(fail_ids: [bad.notion_id], by_id: {
      trashed.notion_id => problem_data(id: trashed.notion_id, project_ids: %w[p1], archived: true),
      live.notion_id => live.data,
    })
    stats = sync_with(client).recheck
    assert_equal [bad.notion_id, trashed.notion_id, live.notion_id], client.fetched
    assert_equal({ candidates: 3, checked: 3, gone: 0, trashed: 1, updated: 0, unchanged: 1, errors: 1 }, stats)
    assert_nil bad.reload.deleted_at, "a refused fetch is not evidence the row is gone"
    assert_equal NOW, bad.synced_at
    assert NotionPage.with_deleted.find(trashed.id).deleted?
    assert_equal NOW, live.reload.synced_at
  end

  test "a recheck in which every fetch failed raises, and deletes nothing" do
    rows = Array.new(3) { |i| observation!(project_ids: %w[p1], synced_at: NOW - (i + 1).hours) }
    client = FakeNotion.new(fail_ids: rows.map(&:notion_id))
    error = assert_raises(Stacks::Notion::Error) { sync_with(client).recheck }
    assert_match(/3 of 3/, error.message)
    assert_equal 3, client.fetched.size
    assert_equal 3, NotionPage.observations.count
  end

  test "a dry run makes no by-id call and says how many it would make" do
    observation!(project_ids: %w[p1], synced_at: NOW - 1.day)
    client = FakeNotion.new
    assert_equal({ candidates: 1, checked: 0 }, sync_with(client).recheck(dry_run: true).slice(:candidates, :checked))
    assert_empty client.fetched
  end

  test "run_all syncs observations, then problems, then rechecks" do
    problem = problem_data(project_ids: [])
    obs = observation_data(project_ids: %w[p1], problem_ids: [problem["id"]])
    client = FakeNotion.new(pages: { OBS => [[obs]], PROB => [[problem, problem_data(project_ids: %w[p1])]] })
    out = sync_with(client).run_all
    assert_equal %i[observations problems recheck], out.keys
    assert_equal [OBS, PROB], client.queries.map { |q| q[:database_id] }
    assert_equal 1, out[:observations][:created]
    assert_equal 2, out[:problems][:created]
    assert_equal 0, out[:recheck][:candidates], "everything was seen by this run"
    assert_empty client.fetched
    assert NotionPage.problems.exists?(notion_id: problem["id"]), "the problem the observation names is in the table"
  end

  test "a whole run that sees nothing deletes nothing, in these databases or any other" do
    mark!(:OBSERVATIONS, NOW - 1.day)
    mark!(:PROBLEMS, NOW - 1.day)
    observation = observation!(project_ids: %w[p1], synced_at: NOW - 1.day)
    old = observation!(project_ids: %w[p1], synced_at: NOW - 1.day, observed_at: NOW - 200.days)
    problem = problem!(project_ids: [], synced_at: NOW - 1.day)
    lead = NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                              notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]), data: {})
    client = FakeNotion.new(by_id: { observation.notion_id => observation.data, problem.notion_id => problem.data })
    out = sync_with(client).run_all
    assert_equal 0, out[:observations][:seen] + out[:problems][:seen]
    [observation, old, problem, lead].each { |row| assert_nil NotionPage.with_deleted.find(row.id).deleted_at }
    assert_equal [observation.notion_id, problem.notion_id].sort, client.fetched.sort
  end

  test "a dry run of everything writes nothing and makes no by-id call" do
    stored = observation!(project_ids: %w[p1], synced_at: NOW - 1.day)
    client = FakeNotion.new(pages: { OBS => [[observation_data(project_ids: %w[p1])]], PROB => [[problem_data]] })
    out = sync_with(client).run_all(dry_run: true)
    assert_equal [1, 1, 1], [out[:observations][:created], out[:problems][:created], out[:recheck][:candidates]]
    assert_equal [stored.id], NotionPage.pluck(:id)
    assert_empty client.fetched
    assert_empty Stacks::Notion::FilteredSync.marks
  end
end
