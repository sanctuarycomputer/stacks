require 'test_helper'

class StacksProjectLogTest < ActiveSupport::TestCase
  include NotionLogFixtures

  NOW = Time.zone.parse("2026-10-13T12:00:00Z")

  setup do
    System.delete_all
    System.create!(settings: { "notion_filtered_sync_marks" => { "OBSERVATIONS" => "2026-10-13T05:00:00Z" } })
    @tracker, @project = log_tracker!
  end

  def log(**params)
    Stacks::ProjectLog.new(@tracker, now: NOW, **params)
  end

  def obs!(**attrs)
    observation!(**{ project_ids: [@project], observed_at: NOW - 1.day }.merge(attrs))
  end

  def titles(log)
    log.rows.map { |r| r.observation.title }
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "parameters are whitelisted and anything else falls back" do
    l = log(view: "highlights", source: "meet", valence: "negative", page: "3")
    assert_equal ["highlights", "meet", "negative", 3], [l.view, l.source, l.valence, l.page]
    [nil, "", "all", "Attention", ["highlights"], { "a" => 1 }, 7].each do |bad|
      l = log(view: bad, source: bad, valence: bad, page: bad)
      assert_equal ["attention", nil, nil, 1], [l.view, l.source, l.valence, l.page], bad.inspect
    end
    %w[0 -1 1.5 1e3 abc 1000 01].each { |bad| assert_equal 1, log(view: "everything", page: bad).page, bad }
    assert_equal 1, log(view: "attention", page: "4").page, "Needs attention has one page"
  end

  test "needs attention: negative observations of the last 30 days that are not dismissed" do
    obs!(name: "recent negative", valence: "Negative")
    obs!(name: "old negative", valence: "Negative", observed_at: NOW - 31.days)
    obs!(name: "dismissed negative", valence: "Negative", status: "Dismissed")
    obs!(name: "positive", valence: "Positive")
    obs!(name: "neutral", valence: "Neutral")
    obs!(name: "unmarked", valence: nil, type: "FYI")
    observation!(name: "another project", valence: "Negative", project_ids: [SecureRandom.uuid], observed_at: NOW - 1.day)
    assert_equal ["recent negative"], titles(log)
  end

  test "needs attention: escalated rows first, then newest first" do
    obs!(name: "plain new", valence: "Negative", salience: "Low", observed_at: NOW - 1.day)
    obs!(name: "escalated old", valence: "Negative", salience: "High", observed_at: NOW - 9.days)
    obs!(name: "plain old", valence: "Negative", salience: "Medium", observed_at: NOW - 5.days)
    obs!(name: "escalated new", valence: "Negative", salience: "High", observed_at: NOW - 2.days)
    assert_equal ["escalated new", "escalated old", "plain new", "plain old"], titles(log)
    assert_equal [true, true, false, false], log.rows.map(&:escalated)
  end

  test "needs attention: open problems for the project, worst first, then most recently seen" do
    problem!(name: "medium", severity: "Medium", status: "Owned", project_ids: [@project], last_seen: NOW - 1.day)
    problem!(name: "critical old", severity: "Critical", status: "Open", project_ids: [@project], last_seen: NOW - 9.days)
    problem!(name: "critical new", severity: "Critical", status: "Mitigating", project_ids: [@project], last_seen: NOW - 2.days)
    problem!(name: "resolved", severity: "Critical", status: "Resolved", project_ids: [@project])
    problem!(name: "dismissed", severity: "High", status: "Dismissed", project_ids: [@project])
    problem!(name: "elsewhere", severity: "Critical", status: "Open", project_ids: [SecureRandom.uuid])
    assert_equal ["critical new", "critical old", "medium"], log.problems.map(&:title)
    assert_equal [], log(view: "everything").problems
  end

  test "escalated: Negative and High salience, or folded into an unowned High or Critical problem" do
    owned = problem!(severity: "Critical", status: "Owned", project_ids: [])
    unowned = problem!(severity: "High", status: "Open", project_ids: [])
    minor = problem!(severity: "Medium", status: "Open", project_ids: [])
    obs!(name: "high salience", valence: "Negative", salience: "High")
    obs!(name: "unowned problem", valence: "Negative", salience: "Low", problem_ids: [unowned.notion_id])
    obs!(name: "owned problem", valence: "Negative", salience: "Low", problem_ids: [owned.notion_id])
    obs!(name: "minor problem", valence: "Negative", salience: "Medium", problem_ids: [minor.notion_id])
    obs!(name: "unknown problem", valence: "Negative", salience: "Low", problem_ids: [SecureRandom.uuid])
    by_title = log.rows.index_by { |r| r.observation.title }
    assert_equal({ "high salience" => true, "unowned problem" => true, "owned problem" => false,
                   "minor problem" => false, "unknown problem" => false }, by_title.transform_values(&:escalated))
    assert_equal [unowned.notion_id], by_title["unowned problem"].problems.map(&:notion_id)
    assert_equal [], by_title["unknown problem"].problems
  end

  test "escalated: a positive or neutral row is never escalated, whatever its salience or problem" do
    unowned = problem!(severity: "Critical", status: "Open", project_ids: [])
    obs!(name: "positive", valence: "Positive", salience: "High", problem_ids: [unowned.notion_id])
    obs!(name: "neutral", valence: "Neutral", salience: "High")
    assert_equal [false, false], log(view: "everything").rows.map(&:escalated)
  end

  test "escalated: a link held only on the problem's side counts" do
    row = obs!(name: "linked from the problem", valence: "Negative", salience: "Low")
    problem!(severity: "Critical", status: "Open", project_ids: [@project], source_observation_ids: [row.notion_id])
    assert log.rows.first.escalated
    assert_equal 1, log.rows.first.problems.size
  end

  test "escalated: a problem with a blank status counts as nobody's, and a link from a problem under no project counts" do
    blank = problem!(severity: "High", status: nil, project_ids: [])
    obs!(name: "blank status", valence: "Negative", salience: "Low", problem_ids: [blank.notion_id], observed_at: NOW - 3.days)
    reverse = obs!(name: "reverse link", valence: "Negative", salience: "Low", observed_at: NOW - 2.days)
    problem!(severity: "Critical", status: "Parked", project_ids: [], source_observation_ids: [reverse.notion_id])
    obs!(name: "plain", valence: "Negative", salience: "Low", observed_at: NOW - 1.day)
    assert_equal ["reverse link", "blank status", "plain"], titles(log)
    assert_equal [true, true, false], log.rows.map(&:escalated)
  end

  test "escalated: a trashed problem escalates nothing" do
    gone = problem!(severity: "Critical", status: "Open", project_ids: [])
    obs!(name: "was escalated", valence: "Negative", salience: "Low", problem_ids: [gone.notion_id])
    gone.destroy
    assert_equal [false], log.rows.map(&:escalated)
    assert_equal 0, Stacks::ProjectLog.summary(@tracker, now: NOW)[:escalated]
  end

  test "escalated is computed with the same number of queries for 2 rows as for 8" do
    make = lambda do |n|
      n.times { obs!(valence: "Negative", problem_ids: [problem!(severity: "High", status: "Open", project_ids: []).notion_id]) }
    end
    read = -> { l = log; l.rows.size; l.problems.size }
    make.(2)
    few = count_queries { read.call }
    make.(6)
    many = count_queries { read.call }
    assert_equal few, many
    assert_operator few, :<=, 3
  end

  test "highlights: every row with a valence that is not dismissed, newest first, any age" do
    obs!(name: "old positive", valence: "Positive", observed_at: NOW - 80.days)
    obs!(name: "neutral", valence: "Neutral", observed_at: NOW - 3.days)
    obs!(name: "negative", valence: "Negative", observed_at: NOW - 1.day)
    obs!(name: "dismissed", valence: "Positive", status: "Dismissed")
    obs!(name: "unmarked", valence: nil, type: "FYI")
    assert_equal ["negative", "neutral", "old positive"], titles(log(view: "highlights"))
  end

  test "highlights group by week, Monday first" do
    obs!(name: "tue", valence: "Positive", observed_at: Time.zone.parse("2026-10-13T09:00:00Z"))
    obs!(name: "mon", valence: "Positive", observed_at: Time.zone.parse("2026-10-12T09:00:00Z"))
    obs!(name: "sun before", valence: "Positive", observed_at: Time.zone.parse("2026-10-11T09:00:00Z"))
    weeks = log(view: "highlights").weeks
    assert_equal [Date.new(2026, 10, 12), Date.new(2026, 10, 5)], weeks.map(&:first)
    assert_equal [%w[tue mon], ["sun before"]], weeks.map { |(_, rows)| rows.map { |r| r.observation.title } }
  end

  test "everything: every synced row for the project, dismissed and unmarked included" do
    obs!(name: "dismissed", valence: "Negative", status: "Dismissed", observed_at: NOW - 2.days)
    obs!(name: "unmarked", valence: nil, type: "FYI", observed_at: NOW - 1.day)
    obs!(name: "ancient", valence: nil, type: "Lead", observed_at: NOW - 300.days)
    assert_equal %w[unmarked dismissed ancient], titles(log(view: "everything"))
  end

  test "interim: before Valence exists the page still has something to show" do
    obs!(name: "a risk", valence: nil, valence_property: false, type: "Risk", salience: "High")
    obs!(name: "a win", valence: nil, valence_property: false, type: "Win")
    obs!(name: "an fyi", valence: nil, valence_property: false, type: "FYI")
    assert_equal ["a risk"], titles(log)
    assert log.rows.first.escalated, "an inferred Negative of High salience is escalated like any other"
    assert log.interim_in_use?
    assert_equal ["a risk", "a win"].sort, titles(log(view: "highlights")).sort
    assert_equal 3, log(view: "everything").rows.size
    assert_equal ["a win"], titles(log(view: "everything", valence: "positive"))
  end

  test "interim_in_use? is false once the rows shown carry a valence" do
    obs!(valence: "Negative", type: "Risk")
    assert_not log.interim_in_use?
  end

  test "chips filter by source group and by valence, with any view" do
    obs!(name: "twist neg", source: "Twist", valence: "Negative")
    obs!(name: "meet neg", source: "Gemini Notes", valence: "Negative")
    obs!(name: "mail pos", source: "google_groups", valence: "Positive")
    obs!(name: "notion neutral", source: "Notion (Tasks)", valence: "Neutral")
    obs!(name: "sentry none", source: "Sentry", valence: nil, type: "Bug")
    assert_equal ["meet neg"], titles(log(source: "meet"))
    assert_equal ["mail pos"], titles(log(view: "highlights", source: "mail"))
    assert_equal ["notion neutral"], titles(log(view: "everything", valence: "neutral"))
    assert_equal ["sentry none"], titles(log(view: "everything", source: "other"))
    assert_equal [], titles(log(view: "everything", source: "twist", valence: "positive"))
    assert log(source: "meet").filtered?
    assert_not log.filtered?
  end

  test "everything and highlights read 200 stored rows a page" do
    203.times { |i| obs!(name: "row #{i}", valence: "Positive", observed_at: NOW - (i + 1).minutes) }
    first = log(view: "everything")
    assert_equal 200, first.rows.size
    assert_equal "row 0", first.rows.first.observation.title
    assert_equal 2, first.older_page
    assert_nil first.newer_page
    second = log(view: "everything", page: "2")
    assert_equal ["row 200", "row 201", "row 202"], titles(second)
    assert_nil second.older_page
    assert_equal 1, second.newer_page
    assert_equal 200, log(view: "highlights").rows.size
    assert_empty log(view: "everything", page: "9").rows
  end

  # The gate, Dismissed and the chips are applied by the database before the
  # limit, so a page is never short while older pages still hold rows.
  test "a Highlights page is filled from gated rows however many ungated rows are newer" do
    Stacks::ProjectLog.stub_const(:PER_PAGE, 2) do
      5.times { |i| obs!(name: "unmarked #{i}", valence: nil, type: "FYI", observed_at: NOW - (i + 1).minutes) }
      obs!(name: "dismissed", valence: "Positive", status: "Dismissed", observed_at: NOW - 30.minutes)
      3.times { |i| obs!(name: "win #{i}", valence: "Positive", observed_at: NOW - (i + 1).hours) }
      first = log(view: "highlights")
      assert_equal ["win 0", "win 1"], titles(first)
      assert_equal 2, first.older_page
      second = log(view: "highlights", page: "2")
      assert_equal ["win 2"], titles(second)
      assert_nil second.older_page
    end
  end

  test "a chip is applied before the page is cut" do
    Stacks::ProjectLog.stub_const(:PER_PAGE, 2) do
      4.times { |i| obs!(name: "twist #{i}", source: "Twist", valence: "Positive", observed_at: NOW - (i + 1).minutes) }
      obs!(name: "meet", source: "Meet", valence: "Positive", observed_at: NOW - 1.hour)
      obs!(name: "meet negative", source: "Meet", valence: "Negative", observed_at: NOW - 2.hours)
      assert_equal ["meet", "meet negative"], titles(log(view: "everything", source: "meet"))
      assert_equal ["meet negative"], titles(log(view: "everything", source: "meet", valence: "negative"))
      assert_nil log(view: "everything", source: "meet").older_page
    end
  end

  test "needs attention holds every negative of the window, however many other rows are newer" do
    Stacks::ProjectLog.stub_const(:ATTENTION_LIMIT, 3) do
      6.times { |i| obs!(name: "win #{i}", valence: "Positive", observed_at: NOW - (i + 1).minutes) }
      obs!(name: "older negative", valence: "Negative", observed_at: NOW - 20.days)
      obs!(name: "oldest escalated", valence: "Negative", salience: "High", observed_at: NOW - 29.days)
      l = log
      assert_equal ["oldest escalated", "older negative"], titles(l)
      assert_not l.capped?
    end
  end

  test "past the cap, needs attention keeps the escalated rows" do
    Stacks::ProjectLog.stub_const(:ATTENTION_LIMIT, 2) do
      3.times { |i| obs!(name: "plain #{i}", valence: "Negative", salience: "Low", observed_at: NOW - (i + 1).hours) }
      obs!(name: "escalated", valence: "Negative", salience: "High", observed_at: NOW - 25.days)
      l = log
      assert_equal ["escalated", "plain 0"], titles(l)
      assert l.capped?
    end
  end

  test "request parameters never reach the SQL" do
    obs!(name: "neg", valence: "Negative")
    sql = []
    grab = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(grab, "sql.active_record") do
      log(view: "everything'; DROP TABLE notion_pages; --", source: "twist' OR '1'='1", valence: "negative' --", page: "2; SELECT 1").rows
    end
    assert_empty sql.grep(/DROP TABLE|'1'='1|SELECT 1\z|negative' --/)
    assert NotionPage.exists?
  end

  test "needs attention reads at most 500 rows and says when it hit the cap" do
    assert_not log.capped?
    Stacks::ProjectLog.stub_const(:ATTENTION_LIMIT, 3) do
      5.times { |i| obs!(name: "neg #{i}", valence: "Negative", observed_at: NOW - (i + 1).hours) }
      l = log
      assert_equal 3, l.rows.size
      assert l.capped?
      assert_nil l.older_page
    end
  end

  test "empty_reason says why there is nothing, most basic cause first" do
    assert_equal :nothing_seen, log.empty_reason
    obs!(valence: nil, type: "FYI")
    assert_nil log.empty_reason, "a project with rows is never 'empty', even when this view shows none"
    assert_empty log.rows

    System.first.update!(notion_filtered_sync_marks: {})
    assert_equal :never_synced, log.empty_reason

    no_project, = log_tracker!(project: nil)
    assert_equal :no_notion_project, Stacks::ProjectLog.new(no_project, now: NOW).empty_reason

    removed, id = log_tracker!
    NotionPage.find_by!(notion_id: id).destroy
    assert_equal :no_notion_project, Stacks::ProjectLog.new(removed, now: NOW).empty_reason
  end

  test "a project with only a problem is not empty" do
    problem!(project_ids: [@project])
    assert_nil log.empty_reason
  end

  test "rows with broken data are shown, not raised on" do
    NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                       notion_parent_id: Stacks::Notion.filtered_parent_id(:OBSERVATIONS),
                       data: { "properties" => "nonsense" }, project_ids: [@project], occurred_at: NOW - 1.day)
    NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                       notion_parent_id: Stacks::Notion.filtered_parent_id(:PROBLEMS),
                       data: {}, project_ids: [@project], occurred_at: nil)
    everything = log(view: "everything")
    assert_equal ["Untitled"], titles(everything)
    assert_equal [false], everything.rows.map(&:escalated)
    assert_equal ["Untitled"], log.problems.map(&:title)
    assert_equal [], log(view: "highlights").weeks
  end

  test "pill_for: red when escalated, orange negative, green positive, grey neutral or unmarked" do
    make = ->(valence, escalated) do
      o = NotionPage.new(notion_id: "x", data: observation_data(valence: valence, type: "FYI")).as_observation
      Stacks::ProjectLog::Row.new(observation: o, problems: [], escalated: escalated)
    end
    assert_equal ["pill error", "Escalated", false], Stacks::ProjectLog.pill_for(make.("Negative", true))
    assert_equal ["pill at_risk", "Negative", false], Stacks::ProjectLog.pill_for(make.("Negative", false))
    assert_equal ["pill exceptional", "Positive", false], Stacks::ProjectLog.pill_for(make.("Positive", false))
    assert_equal ["pill", "Neutral", true], Stacks::ProjectLog.pill_for(make.("Neutral", false))
    assert_equal ["pill", "Not marked", true], Stacks::ProjectLog.pill_for(make.(nil, false))
  end

  test "summary counts what Needs attention shows and takes its first three rows" do
    problem!(severity: "High", status: "Open", project_ids: [@project])
    problem!(severity: "Low", status: "Resolved", project_ids: [@project])
    obs!(name: "n1", valence: "Negative", salience: "Low", observed_at: NOW - 1.day)
    obs!(name: "n2", valence: "Negative", salience: "High", observed_at: NOW - 2.days)
    obs!(name: "n3", valence: "Negative", salience: "Low", observed_at: NOW - 3.days)
    obs!(name: "n4", valence: "Negative", salience: "Low", observed_at: NOW - 4.days)
    obs!(name: "old", valence: "Negative", observed_at: NOW - 40.days)
    obs!(name: "win", valence: "Positive")
    s = Stacks::ProjectLog.summary(@tracker, now: NOW)
    assert_nil s[:empty_reason]
    assert_equal 1, s[:open_problems]
    assert_equal 4, s[:negatives]
    assert_equal 1, s[:escalated]
    assert_equal %w[n2 n1 n3], s[:latest].map { |r| r.observation.title }
    assert_equal [true, false, false], s[:latest].map(&:escalated)
  end

  test "summary counts in SQL and loads only the three rows it shows" do
    7.times { |i| obs!(name: "neg #{i}", valence: "Negative", observed_at: NOW - (i + 1).hours) }
    loaded = 0
    counter = ->(*, payload) { loaded += payload[:record_count] if payload[:class_name] == "NotionPage" }
    s = ActiveSupport::Notifications.subscribed(counter, "instantiation.active_record") do
      Stacks::ProjectLog.summary(@tracker, now: NOW)
    end
    assert_equal 7, s[:negatives]
    assert_equal 3, s[:latest].size
    assert_operator loaded, :<=, 4, "three observations and the tracker's Notion project page, not every negative row"
  end

  test "summary runs the same number of queries for 1 row as for 6" do
    obs!(valence: "Negative")
    one = count_queries { Stacks::ProjectLog.summary(@tracker, now: NOW) }
    5.times { obs!(valence: "Negative", problem_ids: [problem!(project_ids: []).notion_id]) }
    assert_equal one, count_queries { Stacks::ProjectLog.summary(@tracker, now: NOW) }
    assert_operator one, :<=, 7
  end

  test "summary counts an escalated row that is not among the three it shows" do
    unowned = problem!(severity: "Critical", status: nil, project_ids: [])
    5.times { |i| obs!(name: "e#{i}", valence: "Negative", salience: "Low", problem_ids: [unowned.notion_id], observed_at: NOW - (i + 1).hours) }
    obs!(name: "plain", valence: "Negative", salience: "Low", observed_at: NOW - 1.minute)
    s = Stacks::ProjectLog.summary(@tracker, now: NOW)
    assert_equal [6, 5], s.values_at(:negatives, :escalated)
    assert_equal %w[e0 e1 e2], s[:latest].map { |r| r.observation.title }
  end

  test "summary for a tracker with nothing gives the reason and zeroes" do
    s = Stacks::ProjectLog.summary(@tracker, now: NOW)
    assert_equal :nothing_seen, s[:empty_reason]
    assert_equal [0, 0, 0, []], s.values_at(:open_problems, :negatives, :escalated, :latest)
  end

  # --- review fixes ----------------------------------------------------------

  # Needs attention never holds a Dismissed row, so the SQL never counts one.
  # Everything does, and the Ruby rule must not paint it red there.
  test "escalated: a Dismissed row is never escalated, by salience or by problem" do
    unowned = problem!(severity: "Critical", status: "Open", project_ids: [])
    obs!(name: "dismissed high", valence: "Negative", salience: "High", status: "Dismissed", observed_at: NOW - 1.day)
    obs!(name: "dismissed folded", valence: "Negative", salience: "Low", status: "Dismissed",
         problem_ids: [unowned.notion_id], observed_at: NOW - 2.days)
    obs!(name: "live high", valence: "Negative", salience: "High", observed_at: NOW - 3.days)
    everything = log(view: "everything")
    assert_equal ["dismissed high", "dismissed folded", "live high"], titles(everything)
    assert_equal [false, false, true], everything.rows.map(&:escalated)
    assert_equal ["Negative", "Negative", "Escalated"], everything.rows.map { |r| Stacks::ProjectLog.pill_for(r)[1] }
    assert_equal [1, 1], log.attention_counts, "the SQL counts agree"
  end

  test "escalated in SQL: a row whose only problem is Owned or Mitigating is not escalated" do
    owned = problem!(severity: "Critical", status: "Owned", project_ids: [])
    obs!(name: "owned", valence: "Negative", salience: "Low", problem_ids: [owned.notion_id], observed_at: NOW - 1.day)
    mitigated = obs!(name: "mitigating", valence: "Negative", salience: "Low", observed_at: NOW - 2.days)
    problem!(severity: "High", status: "Mitigating", project_ids: [], source_observation_ids: [mitigated.notion_id])
    closed = problem!(severity: "Critical", status: "Resolved", project_ids: [])
    obs!(name: "resolved", valence: "Negative", salience: "Low", problem_ids: [closed.notion_id], observed_at: NOW - 3.days)
    open = problem!(severity: "High", status: "Open", project_ids: [])
    obs!(name: "open", valence: "Negative", salience: "Low", problem_ids: [open.notion_id], observed_at: NOW - 4.days)
    assert_equal [4, 1], log.attention_counts
    assert_equal %w[open owned mitigating resolved], titles(log), "only the open one sorts as escalated"
    assert_equal [true, false, false, false], log.rows.map(&:escalated)
  end

  test "in SQL a stored Valence beats the interim Type mapping" do
    obs!(name: "risk marked positive", type: "Risk", valence: "Positive", salience: "High")
    obs!(name: "win marked negative", type: "Win", valence: "Negative")
    obs!(name: "risk marked neutral", type: "Risk", valence: "Neutral")
    assert_equal ["win marked negative"], titles(log)
    assert_equal [1, 0], log.attention_counts
    assert_equal ["risk marked positive"], titles(log(view: "everything", valence: "positive"))
    assert_equal ["win marked negative"], titles(log(view: "everything", valence: "negative"))
  end

  # The set of escalating problems is worked out once a query, not once a row.
  test "the escalated SQL reads the problems once a query, however many rows and problems there are" do
    make = lambda do |n|
      n.times do |i|
        folded = problem!(severity: "High", status: "Open", project_ids: [])
        row = obs!(valence: "Negative", salience: "Low", problem_ids: [folded.notion_id], observed_at: NOW - (i + 1).hours)
        problem!(severity: "Critical", status: nil, project_ids: [], source_observation_ids: [row.notion_id])
        problem!(severity: "Critical", status: "Owned", project_ids: [])
      end
    end
    read = -> { l = log; [l.rows.map(&:escalated), l.attention_counts, Stacks::ProjectLog.summary(@tracker, now: NOW)[:escalated]] }
    make.(2)
    few = count_queries { assert_equal [[true, true], [2, 2], 2], read.call }
    make.(7)
    many = count_queries { assert_equal [[true] * 9, [9, 9], 9], read.call }
    assert_equal few, many

    l = log
    plan = l.send(:attention_scope).order(Arel.sql(l.send(:attention_order_sql))).explain.to_s
    assert_no_match(/SubPlan/, plan, "no subquery is run again for each row")
    assert_match(/InitPlan/, plan, "the escalating problems are read once, before the rows")
  end
end
