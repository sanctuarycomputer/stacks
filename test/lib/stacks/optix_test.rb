require "test_helper"

class StacksOptixMemberRemovalTest < ActiveSupport::TestCase
  setup do
    @client = Stacks::Optix.new
  end

  test "list_users requests and returns is_admin, is_lead, has_plans" do
    captured_query = nil
    @client.stubs(:execute).with { |**kwargs| captured_query = kwargs[:query]; true }.returns(
      { "users" => { "total" => 1, "data" => [{
        "user_id" => "1", "email" => "a@b.c", "name" => "A", "surname" => "B",
        "is_active" => true, "is_admin" => false, "is_lead" => false, "has_plans" => true,
      }] } }
    )

    users = @client.list_users
    assert_equal 1, users.length
    assert_equal true, users.first["has_plans"]
    %w[is_admin is_lead has_plans].each do |field|
      assert_includes captured_query, field, "list_users query must request #{field}"
    end
  end

  test "user_id_to_member_id_map pages invoices and keeps the first mapping seen" do
    page1 = { "invoices" => { "total" => 3, "data" => Array.new(100) { |i|
      { "invoice_id" => i.to_s, "member" => { "member_id" => 200, "user" => { "user_id" => "50" } } }
    } } }
    page2 = { "invoices" => { "total" => 3, "data" => [
      { "invoice_id" => "x", "member" => { "member_id" => 201, "user" => { "user_id" => "51" } } },
      { "invoice_id" => "y", "member" => { "member_id" => 999, "user" => { "user_id" => "50" } } },
      { "invoice_id" => "z", "member" => nil },
    ] } }
    @client.stubs(:execute).returns(page1).then.returns(page2)

    map = @client.user_id_to_member_id_map
    assert_equal 200, map["50"] # first mapping wins
    assert_equal 201, map["51"]
    assert_equal 2, map.size    # nil member rows are skipped
  end

  test "member_remove_preview returns the ChangeInvoice hash" do
    @client.stubs(:execute).with { |**kwargs|
      kwargs[:query].include?("memberRemovePreview") && kwargs[:variables] == { member_id: "204095" }
    }.returns({ "memberRemovePreview" => { "total" => 0.0, "subtotal" => 0.0, "invoice_due_timestamp" => 123 } })

    preview = @client.member_remove_preview(204095)
    assert_equal 0.0, preview["total"]
  end

  test "member_remove! sends the mutation with a LIST member_id and collect_payment" do
    captured = nil
    @client.stubs(:execute).with { |**kwargs| captured = kwargs; true }
      .returns({ "memberRemove" => [{ "member_id" => 204095, "is_active" => false }] })

    removed = @client.member_remove!(204095, collect_payment: true)
    assert_equal 204095, removed["member_id"]
    assert_equal false, removed["is_active"]
    assert_includes captured[:query], "memberRemove"
    assert_equal({ member_id: ["204095"], collect_payment: true }, captured[:variables])
  end

  test "member_remove! tolerates a single-object (non-list) response" do
    @client.stubs(:execute).returns({ "memberRemove" => { "member_id" => 1, "is_active" => false } })
    assert_equal 1, @client.member_remove!(1, collect_payment: false)["member_id"]
  end
end
