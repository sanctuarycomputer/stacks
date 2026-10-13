require 'test_helper'

class StacksNotionPropsTest < ActiveSupport::TestCase
  P = Stacks::Notion::Props

  def page(props)
    { "properties" => props }
  end

  test "every reader returns its empty value for data that is not a page" do
    [nil, "text", 7, [], {}, { "properties" => nil }, { "properties" => [] }, page("Salience" => "High"),
     page("Salience" => { "type" => "select", "select" => "High" })].each do |data|
      assert_nil P.select(data, "Salience")
      assert_equal "", P.text(data, "Salience")
      assert_nil P.url(data, "Salience")
      assert_nil P.time(data, "Salience")
      assert_equal [], P.relation_ids(data, "Salience")
      assert_not P.relation_truncated?(data, "Salience")
      assert_nil P.number(data, "Salience")
      assert_equal [], P.people_names(data, "Salience")
    end
  end

  test "select reads the option name, trimmed, and nil for an empty select" do
    assert_equal "High", P.select(page("Salience" => { "type" => "select", "select" => { "name" => " High " } }), "Salience")
    assert_nil P.select(page("Salience" => { "type" => "select", "select" => nil }), "Salience")
    assert_nil P.select(page("Salience" => { "type" => "select", "select" => { "name" => "" } }), "Salience")
  end

  # Notion can turn a select into a status property. Reading only the select
  # key would then make every Problem read as open.
  test "select also reads a status-type property" do
    assert_equal "Resolved", P.select(page("Status" => { "type" => "status", "status" => { "name" => "Resolved" } }), "Status")
    assert_nil P.select(page("Status" => { "type" => "status", "status" => nil }), "Status")
    assert_nil P.select(page("Status" => { "type" => "status", "status" => "Resolved" }), "Status")
  end

  test "text joins the fragments of a rich text or a title" do
    rich = { "type" => "rich_text", "rich_text" => [{ "plain_text" => "Client " }, { "plain_text" => "is unhappy" }, "junk", nil] }
    assert_equal "Client is unhappy", P.text(page("Observation" => rich), "Observation")
    title = { "type" => "title", "title" => [{ "plain_text" => "Slip" }] }
    assert_equal "Slip", P.text(page("Name" => title), "Name", "title")
    assert_equal "", P.text(page("Name" => { "type" => "title", "title" => [] }), "Name", "title")
  end

  test "url accepts http and https only" do
    ok = page("Source Ref" => { "type" => "url", "url" => "https://twist.com/a/133876/ch/1/t/2/" })
    assert_equal "https://twist.com/a/133876/ch/1/t/2/", P.url(ok, "Source Ref")
    ["javascript:alert(1)", "data:text/html,x", " https://x.test", "ftp://x.test", "", nil, 5,
     "x\nhttps://evil.example", "https://ok.example\njavascript:alert(1)", "javascript:alert(1)\nhttps://ok.example",
     "https://ok.example\n"].each do |bad|
      assert_nil P.url(page("Source Ref" => { "type" => "url", "url" => bad }), "Source Ref"), bad.inspect
    end
  end

  test "time reads a date's start, as a day or a moment, and nil for anything unreadable" do
    day = page("Observed At" => { "type" => "date", "date" => { "start" => "2026-10-01" } })
    assert_equal Time.zone.parse("2026-10-01"), P.time(day, "Observed At")
    moment = page("Observed At" => { "type" => "date", "date" => { "start" => "2026-10-01T14:30:00.000-04:00" } })
    assert_equal Time.utc(2026, 10, 1, 18, 30), P.time(moment, "Observed At").utc
    ["not a date", "2026-13-45", "", nil, 5].each do |bad|
      assert_nil P.time(page("Observed At" => { "type" => "date", "date" => { "start" => bad } }), "Observed At"), bad.inspect
    end
    assert_nil P.time(page("Observed At" => { "type" => "date", "date" => nil }), "Observed At")
  end

  test "relation_ids keeps string ids once each, and says when Notion cut the list" do
    rel = { "type" => "relation", "relation" => [{ "id" => "a" }, { "id" => "a" }, { "id" => "b" }, { "id" => nil }, "x"], "has_more" => true }
    assert_equal %w[a b], P.relation_ids(page("Projects" => rel), "Projects")
    assert P.relation_truncated?(page("Projects" => rel), "Projects")
    assert_not P.relation_truncated?(page("Projects" => rel.merge("has_more" => false)), "Projects")
  end

  test "number and people_names" do
    assert_equal 4, P.number(page("Occurrences" => { "type" => "number", "number" => 4 }), "Occurrences")
    assert_nil P.number(page("Occurrences" => { "type" => "number", "number" => "4" }), "Occurrences")
    people = { "type" => "people", "people" => [{ "name" => "Sam Lead" }, { "name" => nil }, { "id" => "u" }] }
    assert_equal ["Sam Lead"], P.people_names(page("Owner" => people), "Owner")
  end

  test "top reads a top-level key" do
    assert_equal "x", P.top({ "url" => "x" }, "url")
    assert_nil P.top(nil, "url")
  end

  test "formula_text, boolean and flagged tell what Notion states from what it does not say" do
    text = ->(v) { page("Flag" => { "type" => "formula", "formula" => { "type" => "string", "string" => v } }) }
    bool = ->(v) { page("Flag" => { "type" => "formula", "formula" => { "type" => "boolean", "boolean" => v } }) }
    box = ->(v) { page("Flag" => { "type" => "checkbox", "checkbox" => v }) }

    assert_equal "High-salience risk.", P.formula_text(text.(" High-salience risk. "), "Flag")
    assert_equal ["", "", ""], [nil, "", 7].map { |v| P.formula_text(text.(v), "Flag") }
    assert_equal [true, false, false, false], ["x", "", "  \n", nil].map { |v| P.flagged(text.(v), "Flag") }
    assert_equal [true, false, false], [true, false, nil].map { |v| P.flagged(bool.(v), "Flag") }
    assert_equal [true, false], [true, false].map { |v| P.flagged(box.(v), "Flag") }
    assert_equal [true, false], [true, false].map { |v| P.boolean(box.(v), "Flag") }

    unsaid = [nil, {}, page({}), page("Flag" => "x"), box.("true"), box.(nil),
              page("Flag" => { "type" => "select", "select" => { "name" => "true" } }),
              page("Flag" => { "type" => "formula", "formula" => { "type" => "number", "number" => 1 } }),
              page("Flag" => { "type" => "formula", "formula" => nil })]
    unsaid.each do |data|
      assert_nil P.flagged(data, "Flag"), data.inspect
      assert_nil P.formula_text(data, "Flag"), data.inspect
      assert_nil P.boolean(data, "Flag"), data.inspect
    end
  end
end
