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
end
