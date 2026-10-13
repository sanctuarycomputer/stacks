require 'test_helper'

class StacksNotionObservationTest < ActiveSupport::TestCase
  include NotionLogFixtures

  def obs(**attrs)
    NotionPage.new(notion_id: "n-1", page_title: "Stored title", data: observation_data(**attrs)).as_observation
  end

  test "the two databases are not part of the whole-database sync" do
    filtered = Stacks::Notion::FILTERED_DATABASES.values.map { |d| d[:id] }
    assert_equal %w[390131fea2c7808bb216c38b46c3ba55 18d6276a12aa4e0a957f013a69d5bb9a], filtered
    assert_empty filtered & Stacks::Notion::DATABASE_IDS.values
    assert_equal "390131fe-a2c7-808b-b216-c38b46c3ba55", Stacks::Notion.filtered_parent_id(:OBSERVATIONS)
  end

  test "sync_database refuses a filtered database, dashed or not, before any call" do
    client = Stacks::Notion.allocate
    client.expects(:query_database).never
    ["390131fea2c7808bb216c38b46c3ba55", "18d6276a-12aa-4e0a-957f-013a69d5bb9a"].each do |id|
      assert_raises(ArgumentError) { client.sync_database(id) }
    end
  end

  test "it reads every field the log shows" do
    at = Time.zone.parse("2026-10-01T15:00:00Z")
    o = obs(name: "Client unhappy with pace", text: "Asked twice for a date.", source: "Twist",
            source_ref: "https://twist.com/a/133876/ch/9/t/8/", observed_at: at, salience: "High", type: "Risk",
            status: "Triaged", valence: "Negative", project_ids: %w[p1 p2], problem_ids: %w[pr1])
    assert_equal "Client unhappy with pace", o.title
    assert_equal "Asked twice for a date.", o.text
    assert_equal "Twist", o.source
    assert_equal "twist", o.source_group
    assert_equal "https://twist.com/a/133876/ch/9/t/8/", o.source_url
    assert_equal at, o.observed_at
    assert_equal "High", o.salience
    assert_equal "Risk", o.type
    assert_equal "Triaged", o.status
    assert_equal "Negative", o.valence
    assert_not o.valence_inferred?
    assert o.negative?
    assert_not o.dismissed?
    assert_equal %w[p1 p2], o.project_ids
    assert_equal %w[pr1], o.problem_ids
    assert_match %r{\Ahttps://www\.notion\.so/}, o.notion_url
  end

  test "a row with no properties at all reads as empty and never raises" do
    [nil, {}, { "properties" => nil }, { "properties" => "x" }].each do |data|
      o = NotionPage.new(notion_id: "ab-cd", page_title: "", data: data).as_observation
      assert_equal "Untitled", o.title
      assert_equal "", o.text
      assert_nil o.source
      assert_equal "other", o.source_group
      assert_nil o.source_url
      assert_nil o.observed_at
      assert_nil o.salience
      assert_nil o.type
      assert_nil o.status
      assert_nil o.valence
      assert_not o.negative?
      assert_not o.dismissed?
      assert_equal [], o.project_ids
      assert_equal [], o.problem_ids
      assert_equal "https://www.notion.so/garden3d/abcd", o.notion_url
    end
  end

  test "the title falls back to the stored page title" do
    assert_equal "Stored title", obs(name: nil).title
  end

  test "a stray salience or valence reads as none; a stray type is kept as text" do
    assert_nil obs(salience: "Decision").salience
    assert_nil obs(valence: "Ugly").valence
    assert_equal "business", obs(type: "business").type
  end

  test "sources group for the chips" do
    { "Twist" => "twist", "Meet" => "meet", "Google Meet" => "meet", "Gemini Notes" => "meet",
      "Google Groups" => "mail", "google_groups" => "mail", "Gmail" => "mail", "Notion" => "notion",
      "Notion (Milestones)" => "notion", "Stacks/BI" => "other", "Sentry" => "other", nil => "other" }.each do |source, group|
      assert_equal group, obs(source: source).source_group, source.inspect
    end
  end

  test "interim: with no valence, a Risk shows as Negative and a Win as Positive" do
    risk = obs(type: "Risk", valence: nil, valence_property: false)
    assert_equal "Negative", risk.valence
    assert risk.valence_inferred?
    assert_nil risk.stored_valence
    win = obs(type: "Win", valence: nil)
    assert_equal "Positive", win.valence
    assert win.valence_inferred?
    assert_nil obs(type: "FYI", valence: nil).valence
    assert_nil obs(type: "Decision", valence: nil).valence
  end

  test "interim: a stored valence always wins over the type" do
    o = obs(type: "Risk", valence: "Neutral")
    assert_equal "Neutral", o.valence
    assert_not o.valence_inferred?
    assert_not o.negative?
  end

  test "interim: the rule is one constant" do
    assert_equal({ "Risk" => "Negative", "Win" => "Positive" }, Stacks::Notion::Observation::INTERIM_VALENCE_BY_TYPE)
    Stacks::Notion::Observation.stub_const(:INTERIM_VALENCE_BY_TYPE, {}.freeze) do
      assert_nil obs(type: "Risk", valence: nil).valence
    end
  end

  test "the date falls back to when the row was created" do
    data = observation_data(observed_at: nil, edited: Time.zone.parse("2026-09-01T00:00:00Z"))
    assert_equal Time.zone.parse("2026-09-01T00:00:00Z"), Stacks::Notion::Observation.occurred_at_in(data)
    assert_nil Stacks::Notion::Observation.occurred_at_in(nil)
  end

  test "a source link that is not a web address is not offered" do
    assert_nil obs(source_ref: "javascript:alert(1)").source_url
  end

  test "flag? is Notion's Flag when the page has one, in either shape, and the interim rule only when it has none" do
    make = ->(**attrs) { NotionPage.new(notion_id: "n", data: observation_data(**attrs)).as_observation }
    %i[checkbox formula].each do |shape|
      assert make.(valence: "Positive", salience: "Low", flag: true, flag_shape: shape).flag?, shape.to_s
      assert_not make.(valence: "Negative", salience: "High", flag: false, flag_shape: shape).flag?, shape.to_s
      assert_not make.(flag: true, flag_shape: shape).flag_inferred?
      assert_not make.(flag: false, flag_shape: shape).flag_inferred?
    end
    assert make.(valence: "Negative", salience: "High").flag?
    assert make.(valence: nil, valence_property: false, type: "Risk", salience: "High").flag?, "the interim valence feeds the interim flag"
    assert_not make.(valence: "Negative", salience: "Medium").flag?
    assert_not make.(valence: "Positive", salience: "High").flag?
    assert_not make.(valence: "Negative", salience: "High", status: "Dismissed").flag?
    assert make.(valence: "Negative", salience: "High").flag_inferred?
  end

  test "a text Flag: any text is a flag and is the reason; empty text is Notion saying no" do
    make = ->(**attrs) { NotionPage.new(notion_id: "n", data: observation_data(**attrs)).as_observation }
    said = make.(valence: "Positive", salience: "Low", flag: "Risk, not yet tied to a problem.")
    assert said.flag?
    assert_equal "Risk, not yet tied to a problem.", said.flag_reason
    quiet = make.(valence: "Negative", salience: "High", flag: "")
    assert_not quiet.flag?
    assert_not quiet.flag_inferred?
    assert_nil quiet.flag_reason
    assert_nil make.(valence: "Negative", salience: "High").flag_reason
  end
end
