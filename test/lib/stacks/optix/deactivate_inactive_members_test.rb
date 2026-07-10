require "test_helper"

class StacksOptixDeactivateInactiveMembersTest < ActiveSupport::TestCase
  NOW = Time.now.to_i
  DAY = 86_400

  # ---------- helpers ----------

  def user(user_id, email: "#{user_id}@example.com", is_active: true, is_admin: false, is_lead: false, has_plans: false, name: "User", surname: user_id.to_s)
    { "user_id" => user_id, "email" => email, "name" => name, "surname" => surname,
      "is_active" => is_active, "is_admin" => is_admin, "is_lead" => is_lead, "has_plans" => has_plans }
  end

  def plan(user_id, status:, start_ts: NOW - 100 * DAY, end_ts: nil, canceled_ts: nil)
    { "account_plan_id" => SecureRandom.hex(4), "status" => status,
      "start_timestamp" => start_ts, "end_timestamp" => end_ts, "canceled_timestamp" => canceled_ts,
      "access_usage_user" => { "user_id" => user_id, "email" => "#{user_id}@example.com" } }
  end

  def ended_plan(user_id, days_ago:)
    plan(user_id, status: "ENDED", start_ts: NOW - 400 * DAY, end_ts: NOW - days_ago * DAY)
  end

  def stub_client(users:, plans:, member_map: nil)
    client = Stacks::Optix.new
    client.stubs(:list_users).returns(users)
    client.stubs(:list_account_plans).returns(plans)
    default_map = users.each_with_object({}) { |u, h| h[u["user_id"]] = u["user_id"].to_i + 1000 }
    client.stubs(:user_id_to_member_id_map).returns(member_map || default_map)
    client.stubs(:member_remove_preview).returns({ "total" => 0.0, "subtotal" => 0.0 })
    client.stubs(:member_remove!).returns({ "member_id" => 1, "is_active" => false })
    client
  end

  def call(client, grace_days: 7, collect_payment: true)
    Stacks::Optix::DeactivateInactiveMembers.call(client: client, grace_days: grace_days, collect_payment: collect_payment)
  end

  # ---------- happy path ----------

  test "removes a qualifying member: previews then removes with mapped member_id and collect_payment" do
    client = stub_client(users: [user("50")], plans: [ended_plan("50", days_ago: 30)], member_map: { "50" => 204_095 })
    client.expects(:member_remove_preview).with(204_095).returns({ "total" => 12.5 })
    client.expects(:member_remove!).with(204_095, collect_payment: true).returns({ "member_id" => 204_095, "is_active" => false })

    result = call(client)
    assert_equal 1, result.deactivated.length
    entry = result.deactivated.first
    assert_equal "50", entry[:user_id]
    assert_equal 204_095, entry[:member_id]
    assert_equal 12.5, entry[:invoice_total]
    assert_empty result.skipped
    assert_empty result.errors
  end

  # ---------- exclusions ----------

  test "excludes users with an ACTIVE plan" do
    client = stub_client(users: [user("50")], plans: [plan("50", status: "ACTIVE")])
    client.expects(:member_remove!).never
    assert_empty call(client).deactivated
  end

  test "excludes users with an IN_TRIAL plan" do
    client = stub_client(users: [user("50")], plans: [plan("50", status: "IN_TRIAL")])
    client.expects(:member_remove!).never
    assert_empty call(client).deactivated
  end

  test "excludes users with an UPCOMING plan (scheduled return is still membership)" do
    plans = [ended_plan("50", days_ago: 200), plan("50", status: "UPCOMING", start_ts: NOW + 6 * DAY)]
    client = stub_client(users: [user("50")], plans: plans)
    client.expects(:member_remove!).never
    assert_empty call(client).deactivated
  end

  test "excludes users Optix says have plans (has_plans catches team-held plans)" do
    client = stub_client(users: [user("50", has_plans: true)], plans: [ended_plan("50", days_ago: 200)])
    client.expects(:member_remove!).never
    assert_empty call(client).deactivated
  end

  test "excludes admins" do
    client = stub_client(users: [user("50", is_admin: true)], plans: [ended_plan("50", days_ago: 200)])
    client.expects(:member_remove!).never
    assert_empty call(client).deactivated
  end

  test "excludes users who never held a plan (leads / contacts)" do
    client = stub_client(users: [user("50", is_lead: true), user("51")], plans: [])
    client.expects(:member_remove!).never
    assert_empty call(client).deactivated
  end

  test "excludes users who are not active in Optix" do
    client = stub_client(users: [user("50", is_active: false)], plans: [ended_plan("50", days_ago: 200)])
    client.expects(:member_remove!).never
    assert_empty call(client).deactivated
  end

  # ---------- grace period ----------

  test "skips members whose plan ended within the grace period" do
    client = stub_client(users: [user("50")], plans: [ended_plan("50", days_ago: 6)])
    client.expects(:member_remove!).never
    assert_empty call(client).deactivated
  end

  test "removes members whose plan ended after the grace period" do
    client = stub_client(users: [user("50")], plans: [ended_plan("50", days_ago: 8)])
    assert_equal 1, call(client).deactivated.length
  end

  test "a plan canceled before it ever started is not a membership end" do
    # Only plan: scheduled for the future, canceled 200 days ago. It never ran,
    # so there is no evidence of a lapsed membership -> conservative skip.
    plans = [plan("50", status: "CANCELED", start_ts: NOW + 30 * DAY, canceled_ts: NOW - 200 * DAY)]
    client = stub_client(users: [user("50")], plans: plans)
    client.expects(:member_remove!).never
    assert_empty call(client).deactivated
  end

  test "uses canceled_timestamp as the end for started plans without end_timestamp" do
    plans = [plan("50", status: "CANCELED", start_ts: NOW - 100 * DAY, canceled_ts: NOW - 30 * DAY)]
    client = stub_client(users: [user("50")], plans: plans)
    assert_equal 1, call(client).deactivated.length
  end

  # ---------- safety rails ----------

  test "skips (never removes) members missing from the member_id map" do
    client = stub_client(users: [user("50")], plans: [ended_plan("50", days_ago: 30)], member_map: {})
    client.expects(:member_remove!).never

    result = call(client)
    assert_empty result.deactivated
    assert_equal 1, result.skipped.length
    assert_match(/no member_id mapping/, result.skipped.first[:reason])
  end

  test "skips (never removes) members whose preview fails" do
    client = stub_client(users: [user("50")], plans: [ended_plan("50", days_ago: 30)])
    client.stubs(:member_remove_preview).raises(Stacks::Optix::ApiError.new("Optix GraphQL errors: Internal server error"))
    client.expects(:member_remove!).never

    result = call(client)
    assert_equal 1, result.skipped.length
    assert_match(/preview failed/i, result.skipped.first[:reason])
  end

  test "a non-ApiError preview failure (network blip) is skipped and does not abort remaining candidates" do
    users = [user("50"), user("51")]
    plans = [ended_plan("50", days_ago: 30), ended_plan("51", days_ago: 30)]
    client = stub_client(users: users, plans: plans, member_map: { "50" => 1050, "51" => 1051 })
    client.stubs(:member_remove_preview).with(1050).raises(Errno::ECONNRESET)
    client.stubs(:member_remove_preview).with(1051).returns({ "total" => 0.0 })
    client.stubs(:member_remove!).with(1051, collect_payment: true).returns({ "member_id" => 1051, "is_active" => false })

    result = call(client)
    assert_equal 1, result.skipped.length
    assert_equal "50", result.skipped.first[:user_id]
    assert_match(/preview failed/i, result.skipped.first[:reason])
    assert_equal ["51"], result.deactivated.map { |d| d[:user_id] }
  end

  test "a nil preview is skipped, never removed" do
    client = stub_client(users: [user("50")], plans: [ended_plan("50", days_ago: 30)], member_map: { "50" => 1050 })
    client.stubs(:member_remove_preview).returns(nil)
    client.expects(:member_remove!).never

    result = call(client)
    assert_empty result.deactivated
    assert_equal 1, result.skipped.length
    assert_match(/no invoice preview/, result.skipped.first[:reason])
  end

  test "a removal failure is recorded and does not abort remaining removals" do
    users = [user("50"), user("51")]
    plans = [ended_plan("50", days_ago: 30), ended_plan("51", days_ago: 30)]
    client = stub_client(users: users, plans: plans, member_map: { "50" => 1050, "51" => 1051 })
    client.stubs(:member_remove!).with(1050, collect_payment: true).raises(Stacks::Optix::ApiError.new("boom"))
    client.stubs(:member_remove!).with(1051, collect_payment: true).returns({ "member_id" => 1051, "is_active" => false })

    result = call(client)
    assert_equal 1, result.errors.length
    assert_equal "50", result.errors.first[:user_id]
    assert_equal ["51"], result.deactivated.map { |d| d[:user_id] }
  end

  test "passes collect_payment: false through to removals" do
    client = stub_client(users: [user("50")], plans: [ended_plan("50", days_ago: 30)], member_map: { "50" => 1050 })
    client.expects(:member_remove!).with(1050, collect_payment: false).returns({ "member_id" => 1050, "is_active" => false })
    call(client, collect_payment: false)
  end

  test "does not fetch the member map when there are no candidates" do
    client = stub_client(users: [user("50", is_admin: true)], plans: [])
    client.expects(:user_id_to_member_id_map).never
    call(client)
  end
end
