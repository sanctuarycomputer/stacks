require 'test_helper'

class StacksProjectLogTest < ActiveSupport::TestCase
  include NotionLogFixtures

  NOW = Time.zone.parse("2026-10-13T12:00:00Z")

  setup do
    System.delete_all
    System.create!(settings: { "notion_filtered_sync_marks" => { "OBSERVATIONS" => "2026-10-13T05:00:00Z" } })
    @tracker, @project = log_tracker!
  end

  def log(tracker = @tracker, **params)
    Stacks::ProjectLog.new(tracker, now: NOW, **params)
  end

  def obs!(**attrs)
    observation!(**{ project_ids: [@project], observed_at: NOW - 1.day }.merge(attrs))
  end

  # A row that is a flag on its own: Negative, High salience, recent.
  def risk!(**attrs)
    obs!(**{ valence: "Negative", salience: "High" }.merge(attrs))
  end

  def prob!(**attrs)
    problem!(**{ project_ids: [@project], severity: "High", status: "Open", last_seen: NOW - 1.day }.merge(attrs))
  end

  def titles(log)
    log.rows.map { |r| r.observation.title }
  end

  def flag_titles(log = self.log)
    log.flags.map(&:title)
  end

  def count_queries
    count = 0
    counter = ->(*, payload) { count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end

  test "parameters are whitelisted and anything else falls back" do
    l = log(source: "meet", valence: "negative", page: "3")
    assert_equal ["meet", "negative", 3], [l.source, l.valence, l.page]
    [nil, "", "all", "Negative", ["twist"], { "a" => 1 }, 7].each do |bad|
      l = log(source: bad, valence: bad, page: bad)
      assert_equal [nil, nil, 1], [l.source, l.valence, l.page], bad.inspect
    end
    %w[0 -1 1.5 1e3 abc 1000 01].each { |bad| assert_equal 1, log(page: bad).page, bad }
  end

  # --- what a flag is --------------------------------------------------------

  # --- interim: pages with no Flag in Notion ---------------------------------

  test "interim, no Flag in Notion: a problem flag is open, High or Critical, not picked up, seen in the last 30 days" do
    prob!(name: "critical open", severity: "Critical")
    prob!(name: "high open")
    prob!(name: "high blank status", status: nil)
    prob!(name: "medium open", severity: "Medium")
    prob!(name: "low open", severity: "Low")
    prob!(name: "no severity", severity: nil)
    problem!(name: "elsewhere", severity: "Critical", status: "Open", project_ids: [SecureRandom.uuid], last_seen: NOW - 1.day)
    assert_equal ["critical open", "high blank status", "high open"], flag_titles.sort
    assert_equal 3, log.flag_count
    assert_equal [:problem], log.flags.map(&:kind).uniq
  end

  test "a problem flag clears when it is Resolved or Dismissed in Notion, and leaves the page's problems" do
    prob!(name: "resolved", status: "Resolved")
    prob!(name: "dismissed", severity: "Critical", status: "Dismissed")
    assert_empty log.flags
    assert_empty log.other_problems
  end

  test "a problem flag clears when someone takes it: Owned or Mitigating moves it to the other open problems" do
    prob!(name: "owned", severity: "Critical", status: "Owned", owner: "Sam Lead")
    prob!(name: "mitigating", status: "Mitigating", owner: "Ada")
    assert_empty log.flags
    assert_equal %w[owned mitigating], log.other_problems.map(&:title)
    assert_equal ["Not a flag: Sam Lead owns it.", "Not a flag: Ada is mitigating it."],
                 log.other_problems.map { |p| log.not_a_flag_reason(p) }
  end

  test "interim, no Flag in Notion: a problem flag clears when it has not been seen for 30 days" do
    prob!(name: "fresh", last_seen: NOW - 29.days)
    prob!(name: "stale", last_seen: NOW - 31.days)
    prob!(name: "stale by first seen", last_seen: nil, first_seen: NOW - 40.days)
    prob!(name: "fresh by first seen", last_seen: nil, first_seen: NOW - 3.days)
    assert_equal ["fresh", "fresh by first seen"], flag_titles.sort
    assert_equal ["stale", "stale by first seen"], log.other_problems.map(&:title).sort
    stale = log.other_problems.first
    assert_equal "Not a flag: not seen for 30 days.", log.not_a_flag_reason(stale)
  end

  test "a problem's last sighting is Last Seen, then First Seen, then the row's date; with no date at all it still counts" do
    by_row = prob!(name: "dated by the row only", last_seen: nil, first_seen: nil)
    by_row.update_columns(occurred_at: NOW - 45.days)
    undated = prob!(name: "undated", last_seen: nil, first_seen: nil)
    undated.update_columns(occurred_at: nil)
    # Last Seen wins over an older First Seen and over the row's date.
    recent = prob!(name: "seen again", last_seen: NOW - 2.days, first_seen: NOW - 90.days)
    recent.update_columns(occurred_at: NOW - 90.days)
    assert_equal ["seen again", "undated"], flag_titles.sort
    assert_equal ["dated by the row only"], log.other_problems.map(&:title)
  end

  test "interim, no Flag in Notion: an observation flag is Negative, High salience, not dismissed, in the last 30 days" do
    risk!(name: "recent high negative")
    risk!(name: "edge of the window", observed_at: NOW - 29.days)
    risk!(name: "older than 30 days", observed_at: NOW - 31.days)
    risk!(name: "dismissed", status: "Dismissed")
    obs!(name: "medium negative", valence: "Negative", salience: "Medium")
    obs!(name: "high positive", valence: "Positive", salience: "High")
    obs!(name: "high neutral", valence: "Neutral", salience: "High")
    obs!(name: "high unmarked", valence: nil, type: "FYI", salience: "High")
    observation!(name: "another project", valence: "Negative", salience: "High", project_ids: [SecureRandom.uuid], observed_at: NOW - 1.day)
    assert_equal ["recent high negative", "edge of the window"], flag_titles
    assert_equal [:observation], log.flags.map(&:kind).uniq
    assert_equal 2, log.flag_count
  end

  test "an observation tied to a problem flag is its evidence, not a second flag (the observation's side)" do
    problem = prob!(name: "Timeline slipping")
    tied = risk!(name: "tied", problem_ids: [problem.notion_id])
    risk!(name: "alone")
    l = log
    assert_equal ["Timeline slipping", "alone"], flag_titles(l)
    assert_equal 2, l.flag_count
    assert_equal [tied.notion_id], l.flags.first.evidence.map(&:notion_id)
  end

  test "an observation tied to a problem flag is its evidence, not a second flag (the problem's side)" do
    tied = risk!(name: "tied from the problem")
    prob!(name: "Timeline slipping", severity: "Critical", source_observation_ids: [tied.notion_id])
    l = log
    assert_equal ["Timeline slipping"], flag_titles(l)
    assert_equal 1, l.flag_count
    assert_equal ["tied from the problem"], l.flags.first.evidence.map(&:title)
  end

  test "an observation tied only to a problem that is not a flag here stays a flag of its own" do
    owned = prob!(name: "owned", status: "Owned")
    stale = prob!(name: "stale", last_seen: NOW - 60.days)
    resolved = prob!(name: "resolved", status: "Resolved")
    elsewhere = problem!(name: "elsewhere", severity: "Critical", status: "Open", project_ids: [], last_seen: NOW - 1.day)
    risk!(name: "a", problem_ids: [owned.notion_id], observed_at: NOW - 1.hour)
    risk!(name: "b", problem_ids: [stale.notion_id], observed_at: NOW - 2.hours)
    risk!(name: "c", problem_ids: [resolved.notion_id], observed_at: NOW - 3.hours)
    risk!(name: "d", problem_ids: [elsewhere.notion_id], observed_at: NOW - 4.hours)
    assert_equal %w[a b c d], flag_titles
  end

  test "evidence is this tracker's rows only, never dismissed, the would-be flags first, and capped" do
    problem = prob!(name: "Timeline slipping")
    obs!(name: "old neutral", valence: "Neutral", observed_at: NOW - 80.days, problem_ids: [problem.notion_id])
    obs!(name: "dismissed", valence: "Negative", status: "Dismissed", problem_ids: [problem.notion_id])
    observation!(name: "other project", valence: "Negative", salience: "High", project_ids: [SecureRandom.uuid],
                 observed_at: NOW - 1.day, problem_ids: [problem.notion_id])
    risk!(name: "risk", observed_at: NOW - 5.days, problem_ids: [problem.notion_id])
    obs!(name: "newer note", valence: nil, observed_at: NOW - 1.day, problem_ids: [problem.notion_id])
    flag = log.flags.first
    assert_equal ["risk", "newer note", "old neutral"], flag.evidence.map(&:title)
    assert_equal 0, flag.evidence_more

    Stacks::ProjectLog.stub_const(:EVIDENCE_LIMIT, 2) do
      flag = log.flags.first
      assert_equal ["risk", "newer note"], flag.evidence.map(&:title)
      assert_equal 1, flag.evidence_more
    end
  end

  test "flags: problems worst severity first then most recently seen, then observations newest first" do
    prob!(name: "high old", severity: "High", last_seen: NOW - 9.days)
    prob!(name: "critical old", severity: "Critical", last_seen: NOW - 20.days)
    prob!(name: "high new", severity: "High", last_seen: NOW - 1.day)
    prob!(name: "critical new", severity: "Critical", last_seen: NOW - 2.days)
    risk!(name: "risk old", observed_at: NOW - 6.days)
    risk!(name: "risk new", observed_at: NOW - 1.hour)
    assert_equal ["critical new", "critical old", "high new", "high old", "risk new", "risk old"], flag_titles
  end

  test "why a flag on a page with no Flag in Notion: the interim rule's words" do
    prob!(name: "p1", severity: "High", status: "Open", occurrences: 4, last_seen: Time.zone.parse("2026-10-09T10:00:00Z"))
    prob!(name: "p2", severity: "Critical", status: nil, occurrences: 1, last_seen: Time.zone.parse("2026-10-08T10:00:00Z"))
    prob!(name: "p3", severity: "High", status: "Parked", occurrences: nil, last_seen: nil, first_seen: nil).update_columns(occurred_at: nil)
    risk!(name: "o1", source: "Twist", observed_at: Time.zone.parse("2026-10-09T10:00:00Z"))
    risk!(name: "o2", source: nil, observed_at: Time.zone.parse("2026-10-07T10:00:00Z"))
    why = log.flags.index_by(&:title).transform_values(&:why)
    assert_equal "Open. Seen 4 times, last on Oct 9, 2026.", why["p1"]
    assert_equal "Critical. Last seen on Oct 8, 2026.", why["p2"]
    assert_equal "Open.", why["p3"]
    assert_equal "Risk, not yet tied to a problem. Seen in Twist on Oct 9, 2026.", why["o1"]
    assert_equal "Risk, not yet tied to a problem. Seen on Oct 7, 2026.", why["o2"]
    assert_no_match(/owns/i, why.values.join(" "), "Stacks composes no ownership wording for a flag")
  end

  test "why a flag: Notion's own sentence, then only when Stacks holds it came up" do
    prob!(name: "p", severity: "Medium", status: "Owned", owner: "Sam Lead", occurrences: 3,
          flag: "Open.", last_seen: Time.zone.parse("2026-10-09T10:00:00Z"))
    prob!(name: "p no stop", flag: "Client is unhappy", occurrences: 1, last_seen: Time.zone.parse("2026-10-08T10:00:00Z"))
    obs!(name: "o", valence: "Neutral", source: "Meet", flag: "Risk, not yet tied to a problem.", observed_at: Time.zone.parse("2026-10-09T10:00:00Z"))
    why = log.flags.index_by(&:title).transform_values(&:why)
    assert_equal "Open. Seen 3 times, last on Oct 9, 2026.", why["p"],
                 "the words are Notion's, though the row itself is Medium and Owned"
    assert_equal "Client is unhappy. Last seen on Oct 8, 2026.", why["p no stop"]
    assert_equal "Risk, not yet tied to a problem. Seen in Meet on Oct 9, 2026.", why["o"]
    assert_equal ["Client is unhappy", "Open.", "Risk, not yet tied to a problem."],
                 log.flags.map { |f| f.record.flag_reason }.sort
  end

  test "why a flag that Notion states as a plain yes: a fixed line, then when it came up" do
    prob!(name: "p", severity: nil, status: "Owned", owner: "Sam Lead", flag: true, occurrences: 1, last_seen: Time.zone.parse("2026-10-09T10:00:00Z"))
    obs!(name: "o", valence: "Neutral", salience: nil, source: "Meet", flag: true, flag_shape: :formula, observed_at: Time.zone.parse("2026-10-09T10:00:00Z"))
    why = log.flags.index_by(&:title).transform_values(&:why)
    assert_equal "Flagged in Notion. Last seen on Oct 9, 2026.", why["p"]
    assert_equal "Flagged in Notion. Seen in Meet on Oct 9, 2026.", why["o"]
  end

  # --- Notion's Flag property ------------------------------------------------

  # yes and no in each shape a Flag can take: today's text formula (the
  # reason, or nothing), a boolean formula, a checkbox.
  FLAG_SHAPES = {
    "text" => [{ flag: "Open." }, { flag: "" }],
    "empty text" => [{ flag: "Reason." }, { flag: nil, flag_shape: :text }],
    "formula" => [{ flag: true, flag_shape: :formula }, { flag: false, flag_shape: :formula }],
    "checkbox" => [{ flag: true }, { flag: false }],
  }.freeze

  test "Notion's Flag wins outright when the page has one, in every shape" do
    FLAG_SHAPES.each do |shape, (yes, no)|
      prob!(name: "#{shape} problem: yes beats a Low severity", severity: "Low", **yes)
      prob!(name: "#{shape} problem: yes beats Owned", severity: "Medium", status: "Owned", **yes)
      prob!(name: "#{shape} problem: no beats Critical and Open", severity: "Critical", **no)
      obs!(name: "#{shape} observation: yes beats Positive", valence: "Positive", salience: "Low", **yes)
      risk!(name: "#{shape} observation: no beats a High negative", **no)
    end
    prob!(name: "no Flag: interim says yes")
    prob!(name: "no Flag: interim says no", severity: "Medium")
    risk!(name: "no Flag: interim says yes (observation)")
    l = log
    yeses = FLAG_SHAPES.keys.flat_map do |shape|
      ["#{shape} observation: yes beats Positive", "#{shape} problem: yes beats Owned", "#{shape} problem: yes beats a Low severity"]
    end
    assert_equal (yeses + ["no Flag: interim says yes", "no Flag: interim says yes (observation)"]).sort, flag_titles(l).sort
    assert_equal (FLAG_SHAPES.keys.map { |shape| "#{shape} problem: no beats Critical and Open" } + ["no Flag: interim says no"]).sort,
                 l.other_problems.map(&:title).sort
    assert_nil l.not_a_flag_reason(l.other_problems.find { |p| p.title.start_with?("text") }), "Notion said no; Stacks gives no reason of its own"
  end

  test "a stale Flag never shows a closed problem or a dismissed observation" do
    prob!(name: "resolved", status: "Resolved", flag: "Open.")
    prob!(name: "dismissed", status: "Dismissed", flag: true, flag_shape: :formula)
    obs!(name: "dismissed observation", valence: "Negative", salience: "High", status: "Dismissed", flag: "Risk, not yet tied to a problem.")
    l = log
    assert_empty l.flags
    assert_empty l.other_problems
    assert_equal [false], l.rows.map(&:flag)
  end

  # The 30 days are in Notion's formula now. A page that carries Flag is
  # never tested against a window here, whichever way Notion answered.
  test "Stacks applies no window of its own to a page Notion answered for" do
    prob!(name: "quiet, and Notion still flags it", flag: "Open.", last_seen: NOW - 200.days)
    prob!(name: "recent, and Notion says no", severity: "Critical", flag: "", last_seen: NOW - 1.day)
    prob!(name: "quiet, and Notion says no", severity: "Critical", flag: "", last_seen: NOW - 200.days)
    obs!(name: "old, and Notion still flags it", valence: "Negative", salience: "High", flag: true, observed_at: NOW - 200.days)
    risk!(name: "recent, and Notion says no", flag: "")
    l = log
    assert_equal ["quiet, and Notion still flags it", "old, and Notion still flags it"], flag_titles(l)
    assert_equal ["quiet, and Notion says no", "recent, and Notion says no"], l.other_problems.map(&:title).sort
    l.other_problems.each { |p| assert_nil l.not_a_flag_reason(p), "#{p.title}: Notion decided, so Stacks gives no reason of its own" }
    assert_equal({ @tracker.id => 2 }, Stacks::ProjectLog.flag_counts([@tracker], now: NOW))
    assert_not l.interim_flag_in_use?
  end

  test "the interim rule keeps its window: only a page with no Flag is ever told it was not seen for 30 days" do
    prob!(name: "no Flag, quiet", last_seen: NOW - 31.days)
    risk!(name: "no Flag, old", observed_at: NOW - 31.days)
    l = log
    assert_empty l.flags
    assert_equal "Not a flag: not seen for 30 days.", l.not_a_flag_reason(l.other_problems.first)
    assert_equal({}, Stacks::ProjectLog.flag_counts([@tracker], now: NOW))
  end

  test "an observation Notion flags is still evidence, not a second flag, when tied to a problem flag" do
    problem = prob!(name: "Timeline slipping", severity: "Low", flag: "Open.")
    obs!(name: "tied", valence: "Neutral", flag: "Risk, not yet tied to a problem.", problem_ids: [problem.notion_id])
    obs!(name: "alone", valence: "Neutral", flag: "Risk, not yet tied to a problem.")
    l = log
    assert_equal ["Timeline slipping", "alone"], flag_titles(l)
    assert_equal ["tied"], l.flags.first.evidence.map(&:title)
  end

  test "interim_flag_in_use? says whether any row on the page had no Flag in Notion" do
    prob!(name: "stated", flag: "Open.")
    obs!(name: "stated", valence: "Positive", flag: "")
    assert_not log.interim_flag_in_use?
    obs!(name: "unstated", valence: nil)
    assert log.interim_flag_in_use?
  end

  # Every shape a Flag can take, beside every answer the interim rule gives.
  # The SQL must pick exactly the rows the wrappers call flags.
  test "the flag SQL agrees with flag? row by row" do
    shapes = [[:absent, :checkbox], [true, :checkbox], [false, :checkbox], [true, :formula], [false, :formula], [nil, :formula],
              ["Risk, not yet tied to a problem.", :text], ["", :text], ["  \n\t ", :text], [nil, :text]]
    shapes.each do |(flag, shape)|
      [%w[Critical Open], %w[High Owned], %w[Medium Open], ["High", nil], %w[High Resolved], [nil, "Open"]].each do |(severity, status)|
        prob!(severity: severity, status: status, flag: flag, flag_shape: shape)
      end
      [%w[Negative High New], %w[Negative Low New], %w[Positive High New], %w[Negative High Dismissed], [nil, "High", "New"]].each do |(valence, salience, status)|
        obs!(valence: valence, salience: salience, status: status, flag: flag, flag_shape: shape)
      end
    end
    odd = prob!(severity: "High")
    odd.update_columns(data: odd.data.deep_merge("properties" => { "Flag" => { "type" => "select", "select" => { "name" => "true" } } }))
    odd = prob!(severity: "High")
    odd.update_columns(data: odd.data.deep_merge("properties" => { "Flag" => { "type" => "formula", "formula" => { "type" => "string", "string" => 7 } } }))
    odd = prob!(severity: "High")
    odd.update_columns(data: odd.data.deep_merge("properties" => { "Flag" => { "type" => "formula", "formula" => { "type" => "number", "number" => 1 } } }))
    odd = prob!(severity: "Low")
    odd.update_columns(data: odd.data.deep_merge("properties" => { "Flag" => "nonsense" }))
    odd = prob!(severity: "Low")
    odd.update_columns(data: odd.data.deep_merge("properties" => { "Flag" => { "type" => "checkbox", "checkbox" => "true" } }))

    { problem: [NotionPage.problems, :as_problem], observation: [NotionPage.observations, :as_observation] }.each do |kind, (scope, wrap)|
      in_ruby = scope.select { |row| row.public_send(wrap).flag? }.map(&:notion_id).sort
      in_sql = scope.where(Stacks::ProjectLog.flag_sql(kind)).pluck(:notion_id).sort
      assert_equal in_ruby, in_sql, kind.to_s
      assert_operator in_ruby.size, :>, 5
      assert_operator in_ruby.size, :<, scope.count
    end
  end

  test "a flag's next step is the problem's Proposed Action, else a fixed line" do
    prob!(name: "with action", proposed_action: "  Ask Sam to confirm the date.  ", last_seen: NOW - 1.day)
    prob!(name: "without", proposed_action: nil, last_seen: NOW - 2.days)
    risk!(name: "risk")
    steps = log.flags.index_by(&:title).transform_values(&:next_step)
    assert_equal "Ask Sam to confirm the date.", steps["with action"]
    assert_equal "Pick it up or resolve it in Notion.", steps["without"]
    assert_equal "Read the source. If it is a real problem, raise it; otherwise dismiss it in Notion.", steps["risk"]
  end

  test "interim: before Valence exists a High-salience Risk is a flag and a Win is a win" do
    obs!(name: "a risk", valence: nil, valence_property: false, type: "Risk", salience: "High")
    obs!(name: "a win", valence: nil, valence_property: false, type: "Win")
    obs!(name: "an fyi", valence: nil, valence_property: false, type: "FYI")
    l = log
    assert_equal ["a risk"], flag_titles(l)
    assert_equal ["a win"], l.wins.map { |r| r.observation.title }
    assert l.interim_in_use?
    assert_equal 3, l.rows.size
    assert_equal ["a win"], titles(log(valence: "positive"))
  end

  test "interim_in_use? is false once the rows shown carry a valence" do
    obs!(valence: "Negative", type: "Risk")
    assert_not log.interim_in_use?
  end

  test "a stored Valence beats the interim Type mapping, in the flags, the wins and the filter" do
    obs!(name: "risk marked positive", type: "Risk", valence: "Positive", salience: "High")
    obs!(name: "win marked negative", type: "Win", valence: "Negative", salience: "High")
    obs!(name: "risk marked neutral", type: "Risk", valence: "Neutral", salience: "High")
    l = log
    assert_equal ["win marked negative"], flag_titles(l)
    assert_equal ["risk marked positive"], l.wins.map { |r| r.observation.title }
    assert_equal ["win marked negative"], titles(log(valence: "negative"))
  end

  test "a trashed problem is no flag and absorbs nothing" do
    gone = prob!(name: "gone", severity: "Critical")
    risk!(name: "was evidence", problem_ids: [gone.notion_id])
    assert_equal ["gone"], flag_titles
    gone.destroy
    assert_equal ["was evidence"], flag_titles
  end

  # --- other open problems ---------------------------------------------------

  test "other open problems: the open ones that are not flags, worst first, then most recently seen" do
    prob!(name: "flag", severity: "Critical")
    prob!(name: "medium", severity: "Medium", status: "Owned", owner: "Sam", last_seen: NOW - 1.day)
    prob!(name: "critical owned", severity: "Critical", status: "Mitigating", last_seen: NOW - 2.days)
    prob!(name: "low new", severity: "Low", last_seen: NOW - 1.day)
    prob!(name: "low old", severity: "Low", last_seen: NOW - 9.days)
    prob!(name: "resolved", status: "Resolved")
    l = log
    assert_equal ["critical owned", "medium", "low new", "low old"], l.other_problems.map(&:title)
    reasons = l.other_problems.to_h { |p| [p.title, l.not_a_flag_reason(p)] }
    assert_equal "Not a flag: it is being mitigated.", reasons["critical owned"]
    assert_nil reasons["medium"], "a Medium problem would not be a flag whoever owned it"
    assert_nil reasons["low new"]
  end

  test "ownership in words" do
    words = ->(**attrs) { Stacks::ProjectLog.ownership_words(NotionPage.new(notion_id: "x", data: problem_data(**attrs)).as_problem) }
    assert_equal "Not picked up in Notion yet", words.(status: "Open")
    assert_equal "Owned by Sam Lead", words.(status: "Owned", owner: "Sam Lead")
    assert_equal "Owned, with no owner named in Notion", words.(status: "Owned")
    assert_equal "Being mitigated by Ada", words.(status: "Mitigating", owner: "Ada")
    assert_equal "Being mitigated, with no owner named in Notion", words.(status: "Mitigating")
    assert_equal "Status in Notion: Parked", words.(status: "Parked")
    assert_equal "Not picked up in Notion yet", words.(status: nil)
  end

  # --- wins ------------------------------------------------------------------

  test "wins: Positive observations of the last 30 days that are not dismissed, newest first" do
    obs!(name: "win old", valence: "Positive", observed_at: NOW - 20.days)
    obs!(name: "win new", valence: "Positive", observed_at: NOW - 1.day)
    obs!(name: "too old", valence: "Positive", observed_at: NOW - 31.days)
    obs!(name: "dismissed", valence: "Positive", status: "Dismissed")
    obs!(name: "negative", valence: "Negative")
    l = log
    assert_equal ["win new", "win old"], l.wins.map { |r| r.observation.title }
    assert_equal 2, l.win_count
    assert_not l.more_wins?
  end

  test "wins show a capped list and the full count" do
    Stacks::ProjectLog.stub_const(:WINS_LIMIT, 2) do
      3.times { |i| obs!(name: "win #{i}", valence: "Positive", observed_at: NOW - (i + 1).hours) }
      l = log
      assert_equal ["win 0", "win 1"], l.wins.map { |r| r.observation.title }
      assert_equal 3, l.win_count
      assert l.more_wins?
    end
  end

  test "the source and valence filters do not touch the flags or the wins" do
    risk!(name: "risk", source: "Twist")
    obs!(name: "win", valence: "Positive", source: "Twist")
    l = log(source: "meet", valence: "neutral")
    assert_equal ["risk"], flag_titles(l)
    assert_equal ["win"], l.wins.map { |r| r.observation.title }
    assert_empty l.rows
  end

  # --- all observations ------------------------------------------------------

  test "all observations: every synced row for the project, dismissed and unmarked included, newest first" do
    obs!(name: "dismissed", valence: "Negative", status: "Dismissed", observed_at: NOW - 2.days)
    obs!(name: "unmarked", valence: nil, type: "FYI", observed_at: NOW - 1.day)
    obs!(name: "ancient", valence: nil, type: "Lead", observed_at: NOW - 300.days)
    assert_equal %w[unmarked dismissed ancient], titles(log)
  end

  test "a row says it is part of a flag: a flag itself, or tied to a problem flag from either side" do
    problem = prob!(name: "Timeline slipping")
    owned = prob!(name: "owned", status: "Owned")
    risk!(name: "own flag")
    obs!(name: "tied", valence: "Neutral", salience: "Low", problem_ids: [problem.notion_id])
    reverse = obs!(name: "tied from the problem", valence: nil)
    prob!(name: "Second", source_observation_ids: [reverse.notion_id])
    obs!(name: "tied to an owned problem", valence: "Negative", salience: "Low", problem_ids: [owned.notion_id])
    obs!(name: "tied but dismissed", valence: "Negative", salience: "High", status: "Dismissed", problem_ids: [problem.notion_id])
    obs!(name: "dismissed high", valence: "Negative", salience: "High", status: "Dismissed")
    risk!(name: "too old", observed_at: NOW - 40.days)
    obs!(name: "plain", valence: "Negative", salience: "Low")
    flagged = log.rows.to_h { |r| [r.observation.title, r.flag] }
    assert_equal({ "own flag" => true, "tied" => true, "tied from the problem" => true,
                   "tied to an owned problem" => false, "tied but dismissed" => false, "dismissed high" => false,
                   "too old" => false, "plain" => false }, flagged)
  end

  test "a row carries the problems it was folded into, from either side" do
    unowned = problem!(severity: "High", status: "Open", project_ids: [])
    obs!(name: "named", valence: "Negative", salience: "Low", problem_ids: [unowned.notion_id, SecureRandom.uuid])
    reverse = obs!(name: "reverse", valence: "Negative", salience: "Low")
    reverse_problem = problem!(severity: "Low", status: "Owned", project_ids: [], source_observation_ids: [reverse.notion_id])
    by_title = log.rows.index_by { |r| r.observation.title }
    assert_equal [unowned.notion_id], by_title["named"].problems.map(&:notion_id)
    assert_equal [reverse_problem.notion_id], by_title["reverse"].problems.map(&:notion_id)
  end

  test "filters by source group and by valence" do
    obs!(name: "twist neg", source: "Twist", valence: "Negative")
    obs!(name: "meet neg", source: "Gemini Notes", valence: "Negative")
    obs!(name: "mail pos", source: "google_groups", valence: "Positive")
    obs!(name: "notion neutral", source: "Notion (Tasks)", valence: "Neutral")
    obs!(name: "sentry none", source: "Sentry", valence: nil, type: "Bug")
    assert_equal ["meet neg"], titles(log(source: "meet"))
    assert_equal ["mail pos"], titles(log(source: "mail"))
    assert_equal ["notion neutral"], titles(log(valence: "neutral"))
    assert_equal ["sentry none"], titles(log(source: "other"))
    assert_equal [], titles(log(source: "twist", valence: "positive"))
    assert log(source: "meet").filtered?
    assert_not log.filtered?
  end

  test "all observations read 200 stored rows a page" do
    203.times { |i| obs!(name: "row #{i}", valence: nil, observed_at: NOW - (i + 1).minutes) }
    first = log
    assert_equal 200, first.rows.size
    assert_equal "row 0", first.rows.first.observation.title
    assert_equal 2, first.older_page
    assert_nil first.newer_page
    second = log(page: "2")
    assert_equal ["row 200", "row 201", "row 202"], titles(second)
    assert_nil second.older_page
    assert_equal 1, second.newer_page
    assert_empty log(page: "9").rows
  end

  test "a filter is applied before the page is cut" do
    Stacks::ProjectLog.stub_const(:PER_PAGE, 2) do
      4.times { |i| obs!(name: "twist #{i}", source: "Twist", valence: "Positive", observed_at: NOW - (i + 1).minutes) }
      obs!(name: "meet", source: "Meet", valence: "Positive", observed_at: NOW - 1.hour)
      obs!(name: "meet negative", source: "Meet", valence: "Negative", observed_at: NOW - 2.hours)
      assert_equal ["meet", "meet negative"], titles(log(source: "meet"))
      assert_equal ["meet negative"], titles(log(source: "meet", valence: "negative"))
      assert_nil log(source: "meet").older_page
    end
  end

  test "request parameters never reach the SQL" do
    obs!(name: "neg", valence: "Negative")
    sql = []
    grab = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(grab, "sql.active_record") do
      log(source: "twist' OR '1'='1", valence: "negative' --", page: "2; SELECT 1").load!
    end
    assert_empty sql.grep(/DROP TABLE|'1'='1|SELECT 1\z|negative' --/)
    assert NotionPage.exists?
  end

  test "the page is read with the same number of queries for 2 rows as for 8" do
    make = lambda do |n|
      n.times do
        risk!(problem_ids: [prob!.notion_id])
        risk!
        obs!(valence: "Positive")
      end
    end
    make.(2)
    few = count_queries { log.load! }
    make.(6)
    many = count_queries { log.load! }
    assert_equal few, many
    assert_operator few, :<=, 12
  end

  # --- empty states ----------------------------------------------------------

  test "empty_reason says why there is nothing, most basic cause first" do
    assert_equal :nothing_seen, log.empty_reason
    obs!(valence: nil, type: "FYI")
    assert_nil log.empty_reason, "a project with rows is never 'empty', even with no flags"
    assert_empty log.flags

    System.first.update!(notion_filtered_sync_marks: {})
    assert_equal :never_synced, log.empty_reason

    no_project, = log_tracker!(project: nil)
    assert_equal :no_notion_project, log(no_project).empty_reason

    removed, id = log_tracker!
    NotionPage.find_by!(notion_id: id).destroy
    assert_equal :no_notion_project, log(removed).empty_reason
  end

  test "a project with only a problem is not empty" do
    prob!
    assert_nil log.empty_reason
  end

  test "an empty log has no flags, wins or rows, whatever is stored" do
    risk!(name: "stored")
    System.first.update!(notion_filtered_sync_marks: {})
    l = log.load!
    assert_equal [[], 0, [], [], 0, []], [l.flags, l.flag_count, l.other_problems, l.wins, l.win_count, l.rows]
  end

  test "rows with broken data are shown, not raised on" do
    NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                       notion_parent_id: Stacks::Notion.filtered_parent_id(:OBSERVATIONS),
                       data: { "properties" => "nonsense" }, project_ids: [@project], occurred_at: NOW - 1.day)
    NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                       notion_parent_id: Stacks::Notion.filtered_parent_id(:PROBLEMS),
                       data: {}, project_ids: [@project], occurred_at: nil)
    l = log.load!
    assert_equal ["Untitled"], titles(l)
    assert_equal [false], l.rows.map(&:flag)
    assert_empty l.flags
    assert_equal ["Untitled"], l.other_problems.map(&:title)
    assert_nil l.not_a_flag_reason(l.other_problems.first)
  end

  test "pill_for is the valence: orange negative, green positive, grey neutral; with no valence, the Notion Type in grey" do
    make = ->(valence, flag, type = "FYI") do
      o = NotionPage.new(notion_id: "x", data: observation_data(valence: valence, type: type)).as_observation
      Stacks::ProjectLog::Row.new(observation: o, problems: [], flag: flag)
    end
    assert_equal ["pill at_risk", "Negative", false], Stacks::ProjectLog.pill_for(make.("Negative", true))
    assert_equal ["pill at_risk", "Negative", false], Stacks::ProjectLog.pill_for(make.("Negative", false))
    assert_equal ["pill exceptional", "Positive", false], Stacks::ProjectLog.pill_for(make.("Positive", false))
    assert_equal ["pill", "Neutral", true], Stacks::ProjectLog.pill_for(make.("Neutral", false))
    assert_equal ["pill", "Neutral", true], Stacks::ProjectLog.pill_for(make.("Neutral", false, "Decision")), "a valence always wins over the Type"
    %w[FYI Bug Decision Resourcing].each do |type|
      assert_equal ["pill", type, true], Stacks::ProjectLog.pill_for(make.(nil, false, type))
    end
    assert_equal ["pill", "Not marked", true], Stacks::ProjectLog.pill_for(make.(nil, false, nil)), "only when the Type is blank too"
  end

  # --- the tracker page's module ---------------------------------------------

  test "summary: the flag count, the wins of the last 30 days and the first three flags" do
    prob!(name: "p high", severity: "High", last_seen: NOW - 3.days)
    prob!(name: "p critical", severity: "Critical", last_seen: NOW - 5.days)
    prob!(name: "p owned", severity: "Critical", status: "Owned")
    prob!(name: "p resolved", severity: "Low", status: "Resolved")
    risk!(name: "r1", observed_at: NOW - 1.day)
    risk!(name: "r2", observed_at: NOW - 2.days)
    obs!(name: "plain negative", valence: "Negative", salience: "Low")
    obs!(name: "old", valence: "Negative", salience: "High", observed_at: NOW - 40.days)
    2.times { obs!(valence: "Positive") }
    obs!(valence: "Positive", observed_at: NOW - 40.days)
    s = Stacks::ProjectLog.summary(@tracker, now: NOW)
    assert_nil s[:empty_reason]
    assert_equal 4, s[:flags]
    assert_equal 2, s[:wins]
    assert_equal ["p critical", "p high", "r1"], s[:latest].map(&:title)
    assert_equal log.flag_count, s[:flags]
  end

  test "summary runs the same number of queries for 1 flag as for 6" do
    risk!
    one = count_queries { Stacks::ProjectLog.summary(@tracker, now: NOW) }
    5.times { risk!(problem_ids: [prob!.notion_id]); risk! }
    assert_equal one, count_queries { Stacks::ProjectLog.summary(@tracker, now: NOW) }
    assert_operator one, :<=, 7
  end

  test "summary for a tracker with nothing gives the reason and zeroes" do
    s = Stacks::ProjectLog.summary(@tracker, now: NOW)
    assert_equal :nothing_seen, s[:empty_reason]
    assert_equal [0, 0, []], s.values_at(:flags, :wins, :latest)
  end

  # --- the trackers index ----------------------------------------------------

  # One of each case the rule has, over several trackers. The index's number
  # must be the number of flags the tracker's own log page lists.
  def scenario!
    second_project = project_page!(title: "Harvey Retainer").notion_id
    two_projects = ProjectTracker.new(name: "Two projects", notion_project_ids: [@project, second_project])
    two_projects.save!(validate: false)
    quiet, quiet_project = log_tracker!(name: "Quiet")
    unlinked, = log_tracker!(name: "Unlinked", project: nil)
    removed, removed_project = log_tracker!(name: "Removed from Notion")
    NotionPage.find_by!(notion_id: removed_project).destroy

    # @project: a problem flag absorbing a risk from each side, a lone risk,
    # and rows that are no flag at all.
    absorbed = risk!(name: "absorbed (problem's side)")
    flag = prob!(name: "flag", severity: "Critical", source_observation_ids: [absorbed.notion_id])
    risk!(name: "absorbed (observation's side)", problem_ids: [flag.notion_id])
    risk!(name: "lone risk")
    prob!(name: "owned", status: "Owned")
    prob!(name: "stale", last_seen: NOW - 45.days)
    prob!(name: "resolved", status: "Resolved")
    prob!(name: "medium", severity: "Medium")
    prob!(name: "undated", last_seen: nil).update_columns(occurred_at: nil)
    risk!(name: "dismissed", status: "Dismissed")
    risk!(name: "old", observed_at: NOW - 31.days)
    obs!(name: "win", valence: "Positive")
    # Notion's own Flag in each shape (text formula, boolean formula,
    # checkbox): yes on rows the interim rule would pass over, no on rows it
    # would flag, and a stale yes on closed ones.
    prob!(name: "text yes", severity: "Low", flag: "Open.")
    prob!(name: "formula yes", severity: "Medium", status: "Owned", flag: true, flag_shape: :formula)
    prob!(name: "checkbox yes", severity: "Low", flag: true)
    prob!(name: "text no", severity: "Critical", flag: "")
    prob!(name: "empty text no", severity: "Critical", flag: nil, flag_shape: :text)
    prob!(name: "formula no", severity: "High", flag: false, flag_shape: :formula)
    prob!(name: "checkbox no", severity: "Critical", flag: false)
    prob!(name: "stale yes", status: "Resolved", flag: "Open.")
    # Notion's yes stands however old the page is: the window is Notion's.
    prob!(name: "text yes, long quiet", severity: "Low", flag: "Open.", last_seen: NOW - 45.days)
    obs!(name: "observation text yes, old", valence: "Neutral", flag: "Risk, not yet tied to a problem.", observed_at: NOW - 45.days)
    obs!(name: "observation text yes", valence: "Neutral", salience: "Low", type: "Risk", flag: "Risk, not yet tied to a problem.")
    obs!(name: "observation formula yes", valence: "Positive", flag: true, flag_shape: :formula)
    obs!(name: "observation checkbox yes", valence: "Neutral", salience: "Low", flag: true)
    risk!(name: "observation text no", flag: "")
    risk!(name: "observation formula no", flag: false, flag_shape: :formula)
    risk!(name: "observation checkbox no", flag: false)
    risk!(name: "observation stale yes", status: "Dismissed", flag: "Risk, not yet tied to a problem.")
    # The second project: a flag of its own, a risk filed under both projects
    # (one row, one flag), and a risk tied to the first project's flag.
    problem!(name: "retainer flag", severity: "High", status: "Open", project_ids: [second_project], last_seen: NOW - 2.days)
    observation!(name: "under both", valence: "Negative", salience: "High", project_ids: [@project, second_project], observed_at: NOW - 1.day)
    observation!(name: "retainer risk tied to the first flag", valence: "Negative", salience: "High",
                 project_ids: [second_project], observed_at: NOW - 1.day, problem_ids: [flag.notion_id])
    observation!(name: "quiet win", valence: "Positive", project_ids: [quiet_project], observed_at: NOW - 1.day)
    observation!(name: "filed under a removed project", valence: "Negative", salience: "High",
                 project_ids: [removed_project], observed_at: NOW - 1.day)
    [@tracker, two_projects, quiet, unlinked, removed]
  end

  test "flag_counts gives every tracker the number of flags its log page shows" do
    trackers = scenario!
    counts = Stacks::ProjectLog.flag_counts(trackers, now: NOW)
    shown = trackers.to_h { |t| [t.id, log(t).load!.flags.size] }
    assert_equal shown, trackers.to_h { |t| [t.id, counts.fetch(t.id, 0)] }
    assert_equal [12, 13, 0, 0, 0], trackers.map { |t| counts.fetch(t.id, 0) },
                 "first: flag, undated, lone risk, under both, and the eight Notion says yes to. Both projects: those and the retainer flag; the tied retainer risk is evidence."
    first = log(trackers.first).load!
    assert_equal ["absorbed (observation's side)", "absorbed (problem's side)", "checkbox yes", "flag", "formula yes",
                  "lone risk", "observation checkbox yes", "observation formula yes", "observation text yes",
                  "observation text yes, old", "text yes", "text yes, long quiet", "undated", "under both"],
                 (first.flags.map(&:title) + first.flags.flat_map { |f| f.evidence.map(&:title) }).sort
    trackers.each { |t| assert_equal counts.fetch(t.id, 0), Stacks::ProjectLog.summary(t, now: NOW)[:flags], t.name }
  end

  test "flagged_tracker_ids is exactly the trackers flag_counts gives a number, and empty before the first sync" do
    trackers = scenario!
    counts = Stacks::ProjectLog.flag_counts(trackers, now: NOW)
    assert_equal trackers.first(2).map(&:id).sort, counts.keys.sort
    assert_equal counts.keys.sort, Stacks::ProjectLog.flagged_tracker_ids(now: NOW).sort
    System.first.update!(notion_filtered_sync_marks: {})
    assert_equal [], Stacks::ProjectLog.flagged_tracker_ids(now: NOW)
  end

  test "flag_counts leaves out trackers with no flags" do
    trackers = scenario!
    counts = Stacks::ProjectLog.flag_counts(trackers, now: NOW)
    assert_equal trackers.first(2).map(&:id).sort, counts.keys.sort
  end

  test "flag_counts runs the same few queries for 2 trackers as for 7" do
    make = lambda do |n|
      Array.new(n) do
        tracker, project = log_tracker!
        observation!(valence: "Negative", salience: "High", project_ids: [project], observed_at: NOW - 1.day)
        problem!(severity: "High", status: "Open", project_ids: [project], last_seen: NOW - 1.day)
        tracker
      end
    end
    trackers = make.(2)
    few = count_queries { assert_equal [2, 2], Stacks::ProjectLog.flag_counts(trackers, now: NOW).values }
    trackers += make.(5)
    many = count_queries { assert_equal [2] * 7, Stacks::ProjectLog.flag_counts(trackers, now: NOW).values }
    assert_equal few, many
    assert_operator few, :<=, 4
  end

  test "flag_counts is empty before the first sync, for no trackers, and for trackers with no Notion project" do
    risk!
    assert_equal({ @tracker.id => 1 }, Stacks::ProjectLog.flag_counts([@tracker], now: NOW))
    assert_equal({}, Stacks::ProjectLog.flag_counts([], now: NOW))
    unlinked, = log_tracker!(project: nil)
    assert_equal({}, Stacks::ProjectLog.flag_counts([unlinked], now: NOW))
    System.first.update!(notion_filtered_sync_marks: {})
    assert_equal({}, Stacks::ProjectLog.flag_counts([@tracker], now: NOW))
  end
end
