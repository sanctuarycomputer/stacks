require 'test_helper'

class StacksNotionLeadTest < ActiveSupport::TestCase
  def lead_with_props(props)
    NotionPage.new(data: { "properties" => props }).as_lead
  end

  def status_prop(name)
    { "type" => "status", "status" => { "name" => name } }
  end

  def number_prop(value)
    { "type" => "number", "number" => value }
  end

  test "#lead_status returns the Lead Status name" do
    lead = lead_with_props("Lead Status" => status_prop("Active"))
    assert_equal "Active", lead.lead_status
  end

  test "#lead_status returns nil when the property is missing or empty" do
    assert_nil lead_with_props({}).lead_status
    assert_nil lead_with_props("Lead Status" => { "type" => "status", "status" => nil }).lead_status
  end

  test "#open? is true for Active, Not started, and On hold (re-engage)" do
    ["Active", "Not started", "On hold (re-engage)"].each do |status|
      assert lead_with_props("Lead Status" => status_prop(status)).open?, "expected #{status} to be open"
    end
  end

  test "#open? is false for terminal statuses and missing status" do
    ["Won", "Lost", "Passed", "Cold", "Settled", "Project Paused"].each do |status|
      refute lead_with_props("Lead Status" => status_prop(status)).open?, "expected #{status} to not be open"
    end
    refute lead_with_props({}).open?
  end

  test "#estimated_budget returns the midpoint when both Low and High are set" do
    lead = lead_with_props(
      "Est. Budget Low" => number_prop(40_000),
      "Est. Budget High" => number_prop(60_000)
    )
    assert_equal 50_000, lead.estimated_budget
  end

  test "#estimated_budget returns the single value when only one is set" do
    assert_equal 75_000, lead_with_props("Est. Budget High" => number_prop(75_000)).estimated_budget
    assert_equal 30_000, lead_with_props("Est. Budget Low" => number_prop(30_000)).estimated_budget
  end

  test "#estimated_budget returns nil when neither is set" do
    assert_nil lead_with_props({}).estimated_budget
  end
end
