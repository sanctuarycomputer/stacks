require 'test_helper'

class StacksTaskBuilderDiscoveriesNotionLeadsTest < ActiveSupport::TestCase
  def setup
    @admin = AdminUser.create!(email: "admin@sanctuary.computer", password: "passw0rd")
  end

  def lead_page(props)
    NotionPage.new(data: { "properties" => props })
  end

  def discover(pages)
    NotionPage.stubs(:lead).returns(pages)
    Stacks::TaskBuilder::Discoveries::NotionLeads.new(admin_fallback: [@admin]).tasks
  end

  test "an open lead with no budget yields a needs_budget_estimate task owned by the fallback" do
    tasks = discover([lead_page(
      "Lead Status" => { "type" => "status", "status" => { "name" => "Active" } },
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => Date.today.iso8601 } }
    )])

    task = tasks.find { |t| t.type == :needs_budget_estimate }
    assert task, "expected a needs_budget_estimate task"
    assert_equal [@admin], task.owners
  end

  test "an open lead with a budget yields no needs_budget_estimate task" do
    tasks = discover([lead_page(
      "Lead Status" => { "type" => "status", "status" => { "name" => "Active" } },
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => Date.today.iso8601 } },
      "Est. Budget High" => { "type" => "number", "number" => 50_000 }
    )])

    refute tasks.any? { |t| t.type == :needs_budget_estimate }
  end

  test "a closed lead with no budget yields no needs_budget_estimate task" do
    tasks = discover([lead_page(
      "Lead Status" => { "type" => "status", "status" => { "name" => "Lost" } },
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => Date.today.iso8601 } }
    )])

    refute tasks.any? { |t| t.type == :needs_budget_estimate }
  end

  test "an open unbudgeted lead with an Account Lead routes to that admin user" do
    account_lead = AdminUser.create!(email: "seller@sanctuary.computer", password: "passw0rd")
    tasks = discover([lead_page(
      "Lead Status" => { "type" => "status", "status" => { "name" => "Active" } },
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => Date.today.iso8601 } },
      "Account Lead" => { "type" => "people", "people" => [{ "person" => { "email" => "seller@sanctuary.computer" } }] }
    )])

    task = tasks.find { |t| t.type == :needs_budget_estimate }
    assert task, "expected a needs_budget_estimate task"
    assert_equal [account_lead], task.owners
  end

  test "needs_budget_estimate has an explicit humanized label" do
    assert_equal "Notion lead needs an estimated budget",
      StacksTask::HUMANIZED_TYPES[:needs_budget_estimate]
  end
  # ---- loss_survey_needed ---------------------------------------------------

  def lost_lead(overrides = {})
    lead_page({
      "Lead Status" => { "type" => "status", "status" => { "name" => "Lost" } },
      "✨ Lead Received" => { "type" => "date", "date" => { "start" => (Date.today - 40).iso8601 } },
      "Studio" => { "type" => "multi_select", "multi_select" => [] },
      "✨ Status: Lost" => { "type" => "date", "date" => { "start" => (Date.today - 5).iso8601 } },
      "✨ Proposal Sent" => { "type" => "date", "date" => { "start" => (Date.today - 20).iso8601 } },
      "✨ No Proposal Sent?" => { "type" => "checkbox", "checkbox" => false },
      "Loss Survey" => { "type" => "relation", "relation" => [] },
    }.merge(overrides))
  end

  def loss_survey_task(pages)
    discover(pages).find { |t| t.type == :loss_survey_needed }
  end

  test "a recently lost lead that got a proposal and has no survey yields loss_survey_needed for its Account Lead" do
    seller = AdminUser.create!(email: "closer@sanctuary.computer", password: "passw0rd")
    task = loss_survey_task([lost_lead(
      "Account Lead" => { "type" => "people", "people" => [{ "person" => { "email" => "closer@sanctuary.computer" } }] }
    )])
    assert task, "expected a loss_survey_needed task"
    assert_equal [seller], task.owners
  end

  test "loss_survey_needed falls back to the admins when the lead has no Account Lead" do
    assert_equal [@admin], loss_survey_task([lost_lead]).owners
  end

  test "a linked survey response clears loss_survey_needed" do
    refute loss_survey_task([lost_lead("Loss Survey" => { "type" => "relation", "relation" => [{ "id" => "abc" }] })])
  end

  test "Loss Survey Status Sent or Not sending clears loss_survey_needed" do
    ["Sent", "Not sending"].each do |status|
      refute loss_survey_task([lost_lead("Loss Survey Status" => { "type" => "select", "select" => { "name" => status } })]),
        "#{status} should clear the task"
    end
  end

  test "an empty Loss Survey Status still needs the survey" do
    assert loss_survey_task([lost_lead("Loss Survey Status" => { "type" => "select", "select" => nil })])
  end

  test "no loss_survey_needed when no proposal was sent" do
    refute loss_survey_task([lost_lead("✨ Proposal Sent" => { "type" => "date", "date" => nil })])
    refute loss_survey_task([lost_lead("✨ No Proposal Sent?" => { "type" => "checkbox", "checkbox" => true })])
  end

  test "no loss_survey_needed for Passed leads (we declined; the survey asks why they chose another vendor)" do
    refute loss_survey_task([lost_lead("Lead Status" => { "type" => "status", "status" => { "name" => "Passed" } })])
  end

  test "no loss_survey_needed for leads lost before the rollout date or with no lost date" do
    before = (Stacks::TaskBuilder::Discoveries::NotionLeads::LOSS_SURVEYS_FROM - 1).iso8601
    refute loss_survey_task([lost_lead("✨ Status: Lost" => { "type" => "date", "date" => { "start" => before } })])
    refute loss_survey_task([lost_lead("✨ Status: Lost" => { "type" => "date", "date" => nil })])
  end

  test "loss_survey_needed has an explicit humanized label" do
    assert_equal "Notion lead needs its loss survey sent (or Loss Survey Status set to Not sending)",
      StacksTask::HUMANIZED_TYPES[:loss_survey_needed]
  end
end
