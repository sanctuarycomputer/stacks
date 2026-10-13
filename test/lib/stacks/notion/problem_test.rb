require 'test_helper'

class StacksNotionProblemTest < ActiveSupport::TestCase
  include NotionLogFixtures

  def prob(**attrs)
    NotionPage.new(notion_id: "n-2", page_title: "Stored", data: problem_data(**attrs)).as_problem
  end

  test "it reads every field the log shows" do
    seen = Time.zone.parse("2026-10-05T12:00:00Z")
    p = prob(name: "Timeline slipping", kind: "delivery", severity: "Critical", status: "Open", owner: "Sam Lead",
             occurrences: 4, last_seen: seen, project_ids: %w[p1], source_observation_ids: %w[o1 o2])
    assert_equal "Timeline slipping", p.title
    assert_equal "delivery", p.kind
    assert_equal "Critical", p.severity
    assert_equal 0, p.severity_rank
    assert_equal "Open", p.status
    assert p.open?
    assert p.unowned?
    assert p.interim_flag?
    assert_equal ["Sam Lead"], p.owner_names
    assert_equal 4, p.occurrences
    assert_equal seen, p.last_seen_at
    assert_equal %w[p1], p.project_ids
    assert_equal %w[o1 o2], p.source_observation_ids
  end

  # A blank or unknown status counts as open, for the interim flag too: a problem
  # nobody is known to own should fail visible.
  test "the interim flag rule means High or Critical and not known to be owned or closed" do
    table = { %w[Open Critical] => true, %w[Open High] => true, %w[Open Medium] => false, %w[Open Low] => false,
              %w[Owned Critical] => false, %w[Mitigating High] => false, %w[Resolved Critical] => false,
              %w[Dismissed High] => false, ["Open", nil] => false, [nil, "High"] => true,
              %w[Parked Critical] => true, %w[Parked Medium] => false, [nil, nil] => false }
    table.each do |(status, severity), expected|
      assert_equal expected, prob(status: status, severity: severity).interim_flag?, [status, severity].inspect
    end
  end

  test "unowned means Notion says Open, which is what the page prints" do
    assert prob(status: "Open").unowned?
    [nil, "Parked", "Owned", "Resolved"].each { |status| assert_not prob(status: status).unowned?, status.inspect }
  end

  test "a Status that Notion turned into a status property is still read" do
    data = problem_data(severity: "Critical")
    data["properties"]["Status"] = { "type" => "status", "status" => { "name" => "Resolved" } }
    p = NotionPage.new(notion_id: "n", data: data).as_problem
    assert_equal "Resolved", p.status
    assert_not p.open?
    assert_not p.interim_flag?
  end

  test "open means not Resolved and not Dismissed; a blank or odd status stays visible" do
    { "Open" => true, "Owned" => true, "Mitigating" => true, "Resolved" => false, "Dismissed" => false,
      nil => true, "Parked" => true }.each do |status, expected|
      assert_equal expected, prob(status: status).open?, status.inspect
    end
  end

  test "severity ranks Critical first and an unknown one last" do
    assert_equal [0, 1, 2, 3, 4], ["Critical", "High", "Medium", "Low", "Huge"].map { |s| prob(severity: s).severity_rank }
    assert_nil prob(severity: "Huge").severity
  end

  test "the owner falls back to the Owner Name text" do
    data = problem_data(owner: nil)
    data["properties"]["Owner Name"] = nl_text("rich_text", "Alex PM")
    assert_equal ["Alex PM"], NotionPage.new(notion_id: "n", data: data).as_problem.owner_names
  end

  test "a row with no properties reads as empty and never raises" do
    [nil, {}, { "properties" => [] }].each do |data|
      p = NotionPage.new(notion_id: "ab-cd", page_title: "", data: data).as_problem
      assert_equal "Untitled", p.title
      assert_nil p.severity
      assert_equal 4, p.severity_rank
      assert p.open?
      assert_not p.interim_flag?
      assert_equal [], p.owner_names
      assert_nil p.occurrences
      assert_nil p.last_seen_at
      assert_equal [], p.project_ids
      assert_equal [], p.source_observation_ids
    end
  end

  test "scopes hold each database's rows and nothing else" do
    o = observation!
    p = problem!
    lead = NotionPage.create!(notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
                              notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:LEADS]), data: {})
    assert_equal [o.id], NotionPage.observations.pluck(:id)
    assert_equal [p.id], NotionPage.problems.pluck(:id)
    assert_not_includes NotionPage.observations.pluck(:id) + NotionPage.problems.pluck(:id), lead.id
    assert_kind_of Stacks::Notion::Observation, o.as_observation
    assert_kind_of Stacks::Notion::Problem, p.as_problem
  end

  test "the proposed action is read as plain text, blank when there is none" do
    assert_equal "Ask Sam to confirm the date.", prob(proposed_action: "  Ask Sam to confirm the date. ").proposed_action
    assert_equal "", prob(proposed_action: nil).proposed_action
    data = problem_data
    data["properties"]["Proposed Action"] = { "type" => "select", "select" => { "name" => "x" } }
    assert_equal "", NotionPage.new(notion_id: "n", data: data).as_problem.proposed_action
    data["properties"].delete("Proposed Action")
    assert_equal "", NotionPage.new(notion_id: "n", data: data).as_problem.proposed_action
  end

  test "seen_at is Last Seen, then First Seen, then the stored row's date, else nil" do
    last = Time.zone.parse("2026-10-05T12:00:00Z")
    first = Time.zone.parse("2026-09-01T12:00:00Z")
    row = Time.zone.parse("2026-08-01T12:00:00Z")
    make = ->(occurred_at, **attrs) { NotionPage.new(notion_id: "n", occurred_at: occurred_at, data: problem_data(**attrs)).as_problem }
    assert_equal last, make.(row, last_seen: last, first_seen: first).seen_at
    assert_equal first, make.(row, last_seen: nil, first_seen: first).seen_at
    assert_equal row, make.(row, last_seen: nil, first_seen: nil).seen_at
    assert_nil make.(nil, last_seen: nil, first_seen: nil).seen_at
  end

  test "flag? is Notion's Flag when the page has one, in either shape, and the interim rule only when it has none" do
    %i[checkbox formula].each do |shape|
      assert prob(severity: "Low", status: "Owned", flag: true, flag_shape: shape).flag?, shape.to_s
      assert_not prob(severity: "Critical", status: "Open", flag: false, flag_shape: shape).flag?, shape.to_s
      assert_not prob(flag: true, flag_shape: shape).flag_inferred?
      assert_not prob(flag: false, flag_shape: shape).flag_inferred?
    end
    assert_not prob(severity: "Critical", flag: nil, flag_shape: :formula).flag?, "an empty boolean formula is Notion saying no"
    assert_nil prob(flag: true).flag_reason
    assert_nil prob.flag_reason
    assert prob(severity: "Critical", status: "Open").flag?
    assert_not prob(severity: "Critical", status: "Owned").flag?
    assert_not prob(severity: "Medium", status: "Open").flag?
    assert prob.flag_inferred?
    assert prob(severity: "High", status: "Resolved", flag: true).flag?, "what Notion states is read as stated; the log leaves a closed problem out"
  end

  # What Notion holds today: a formula that gives the reason as text.
  test "a text Flag: any text is a flag and is the reason; empty text is Notion saying no" do
    said = prob(severity: "Low", status: "Owned", flag: "  High severity problem. Nobody owns it yet. ")
    assert said.flag?
    assert_not said.flag_inferred?
    assert_equal "High severity problem. Nobody owns it yet.", said.flag_reason
    ["", "   ", nil].each do |empty|
      quiet = prob(severity: "Critical", status: "Open", flag: empty, flag_shape: :text)
      assert_not quiet.flag?, empty.inspect
      assert_not quiet.flag_inferred?, empty.inspect
      assert_nil quiet.flag_reason, empty.inspect
    end
  end
end
