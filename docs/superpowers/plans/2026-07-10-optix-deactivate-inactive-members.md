# Optix Deactivate Inactive Members — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A daily automation that removes ("deactivates") Optix members of Index Space who no longer hold any membership, per the approved spec `docs/superpowers/specs/2026-07-10-optix-deactivate-inactive-members-design.md`.

**Architecture:** A new service object `Stacks::Optix::DeactivateInactiveMembers` reads users + plans from the live Optix GraphQL API (never the synced DB tables), applies validated selection rules, previews each removal, then removes with `collect_payment: true`. It's wired in via `Enterprise#daily_tasks` (guarded by `is_index?`) called from the `stacks:daily_enterprise_tasks` rake task.

**Tech Stack:** Ruby 3.1 / Rails 6.1, HTTParty (existing `Stacks::Optix` client), Minitest + mocha (stubs — NEVER hit the live API in tests).

## Global Constraints

- No new gems.
- Tests: Minitest under `test/`, mocha for stubs (`obj.stubs(:method).returns(...)`, `obj.expects(:method)`). Run with `bin/rails test <path>`.
- `lib/` is autoloaded AND eager-loaded (Zeitwerk) — `Stacks::Optix::DeactivateInactiveMembers` must live at `lib/stacks/optix/deactivate_inactive_members.rb`.
- Never call the live Optix API from tests. All client methods must be stubbed.
- Optix API facts (validated live, do not "simplify"):
  - `memberRemove(member_id: [ID!]!, collect_payment: Boolean)` — member_id is a **LIST**.
  - `memberRemovePreview(member_id: ID!)` — single ID; **500s with "Internal server error" for unknown IDs**.
  - `member_id ≠ user_id`; the only org-token mapping path is via `invoices { data { member { member_id user { user_id } } } }`.
  - `AccountPlanStatus`: ACTIVE, CANCELED, ENDED, IN_TRIAL, UPCOMING, UNKNOWN.
  - `User.has_plans` = "has active or upcoming plans", including team-held plans.

---

### Task 1: Client additions to `Stacks::Optix`

**Files:**
- Modify: `lib/stacks/optix.rb` (the `list_users` method at ~line 160; new methods after `list_account_plans` which ends ~line 285)
- Create: `test/lib/stacks/optix_test.rb`

**Interfaces:**
- Produces (used by Task 2):
  - `#list_users(page_size: 100)` → `Array<Hash>` now including keys `"is_admin"`, `"is_lead"`, `"has_plans"` (plus existing `"user_id"`, `"email"`, `"name"`, `"surname"`, `"is_active"`)
  - `#user_id_to_member_id_map(page_size: 100)` → `Hash{String => Integer}`
  - `#member_remove_preview(member_id)` → `Hash` (`{"total"=>Float, "subtotal"=>Float, "invoice_due_timestamp"=>Int}`)
  - `#member_remove!(member_id, collect_payment:)` → `Hash` (`{"member_id"=>Int, "is_active"=>Bool}`)

- [ ] **Step 1: Write the failing tests**

Create `test/lib/stacks/optix_test.rb`:

```ruby
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/stacks/optix_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'user_id_to_member_id_map'` etc.; the `list_users` test fails the `assert_includes captured_query, "is_admin"` assertion.

- [ ] **Step 3: Implement**

In `lib/stacks/optix.rb`, update the `list_users` query field set (keep the surrounding method identical):

```ruby
  # Pages through users (members) and returns Array<Hash>. Used by OptixSync
  # to populate optix_users, and by DeactivateInactiveMembers for candidate
  # selection. `is_admin` / `is_lead` / `has_plans` are NOT synced to columns —
  # OptixSync maps an explicit subset and stashes the full payload in `data`.
  def list_users(page_size: 100)
    paginate(page_size: page_size) do |limit, page|
      execute(query: <<~GQL, variables: { limit: limit, page: page })
        query Users($limit: Int, $page: Int) {
          users(limit: $limit, page: $page) {
            total
            data {
              user_id
              email
              name
              surname
              is_active
              is_admin
              is_lead
              has_plans
            }
          }
        }
      GQL
    end
  end
```

Add after `list_account_plans` (before `member_counts_by_tier_and_location`):

```ruby
  # Maps Optix user_id -> member_id. memberRemove / memberRemovePreview take a
  # member_id, which is NOT the same as user_id, and the only organization-token
  # path to the mapping is via invoices (Invoice.member exposes both IDs).
  # Members with no invoices on record are absent from the map — callers must
  # treat a missing key as "cannot safely remove".
  def user_id_to_member_id_map(page_size: 100)
    map = {}
    page = 1
    loop do
      data = execute(query: <<~GQL, variables: { limit: page_size, page: page })
        query Invoices($limit: Int, $page: Int) {
          invoices(limit: $limit, page: $page, include_paid: true, include_void: true, include_upcoming: true) {
            total
            data { invoice_id member { member_id user { user_id } } }
          }
        }
      GQL
      batch = data.dig("invoices", "data") || []
      batch.each do |invoice|
        member = invoice["member"]
        next unless member.is_a?(Hash) && member["user"].is_a?(Hash)
        map[member.dig("user", "user_id")] ||= member["member_id"]
      end
      break if batch.length < page_size
      page += 1
    end
    map
  end

  # Previews the invoice that memberRemove would generate for this member.
  # Read-only. NOTE: Optix responds with a GraphQL "Internal server error"
  # for unknown member_ids (validated live 2026-07-10) — callers should treat
  # ApiError as "cannot safely remove", not as retryable.
  def member_remove_preview(member_id)
    data = execute(query: <<~GQL, variables: { member_id: member_id.to_s })
      query MemberRemovePreview($member_id: ID!) {
        memberRemovePreview(member_id: $member_id) {
          total
          subtotal
          invoice_due_timestamp
        }
      }
    GQL
    data["memberRemovePreview"]
  end

  # Removes (deactivates) a member from the organization. Creates an invoice
  # with any pending charges; collect_payment: true makes it due immediately.
  # Reversible: re-adding the same email reactivates the member.
  #
  # The mutation's member_id arg is a LIST ([ID!]!) per live introspection —
  # we pass exactly one and return the single removed Member payload.
  def member_remove!(member_id, collect_payment:)
    data = execute(query: <<~GQL, variables: { member_id: [member_id.to_s], collect_payment: collect_payment })
      mutation MemberRemove($member_id: [ID!]!, $collect_payment: Boolean) {
        memberRemove(member_id: $member_id, collect_payment: $collect_payment) {
          member_id
          is_active
        }
      }
    GQL
    removed = data["memberRemove"]
    removed.is_a?(Array) ? removed.first : removed
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/stacks/optix_test.rb`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/optix.rb test/lib/stacks/optix_test.rb
git commit -m "feat(optix): client support for member removal (map, preview, remove)"
```

---

### Task 2: `Stacks::Optix::DeactivateInactiveMembers` service

**Files:**
- Create: `lib/stacks/optix/deactivate_inactive_members.rb`
- Modify: `lib/stacks/optix.rb` (add class method `self.deactivate_inactive_members!` — put it right after the `attr_reader :optix_organization` / `initialize` block, ~line 47)
- Create: `test/lib/stacks/optix/deactivate_inactive_members_test.rb`

**Interfaces:**
- Consumes (from Task 1): `client.list_users`, `client.list_account_plans`, `client.user_id_to_member_id_map`, `client.member_remove_preview(member_id)`, `client.member_remove!(member_id, collect_payment:)`, `Stacks::Optix::ApiError`
- Produces (used by Task 3):
  - `Stacks::Optix.deactivate_inactive_members!(grace_days: 7, collect_payment: true)` → `Result`
  - `Stacks::Optix::DeactivateInactiveMembers.call(client:, grace_days: 7, collect_payment: true)` → `Result` with `#deactivated` (Array of `{user_id:, member_id:, email:, name:, invoice_total:}`), `#skipped` (Array of `{user_id:, email:, reason:}`), `#errors` (Array of `{user_id:, email:, error:}`)

- [ ] **Step 1: Write the failing tests**

Create `test/lib/stacks/optix/deactivate_inactive_members_test.rb`:

```ruby
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/lib/stacks/optix/deactivate_inactive_members_test.rb`
Expected: FAIL — `NameError: uninitialized constant Stacks::Optix::DeactivateInactiveMembers`

- [ ] **Step 3: Implement the service**

Create `lib/stacks/optix/deactivate_inactive_members.rb`:

```ruby
# Removes ("deactivates") Optix members who no longer hold any membership.
# Runs daily for Index Space via Enterprise#daily_tasks inside
# stacks:daily_enterprise_tasks.
#
# Selection rules — a user is removed when ALL hold (validated against the
# live API via a read-only dry run reviewed by the Index team; see
# docs/optix-member-deactivation-dry-run.md and the design spec in
# docs/superpowers/specs/2026-07-10-optix-deactivate-inactive-members-design.md):
#
#   1. is_active (they are a current Optix user)
#   2. at least one account plan on record (leads/contacts untouched)
#   3. no plan with status ACTIVE, IN_TRIAL, or UPCOMING — a scheduled
#      future plan is still membership
#   4. has_plans is false (Optix's own flag; catches team-held plans that
#      never appear under accountPlans.access_usage_user)
#   5. their latest plan that actually STARTED ended more than grace_days
#      ago (plans canceled before their start date never ran — their
#      canceled_timestamp is when the cancel was clicked, not a lapse date)
#   6. not an Optix admin
#   7. they can be mapped to a member_id AND memberRemovePreview succeeds;
#      otherwise they are skipped and reported, never removed blind
#
# Reads exclusively from the live API (not the synced optix_* tables) so it
# never acts on stale data. Idempotent: removed members return is_active:
# false and fail rule 1 on subsequent runs.
class Stacks::Optix::DeactivateInactiveMembers
  ACTIVE_PLAN_STATUSES = %w[ACTIVE IN_TRIAL UPCOMING].freeze
  DAY_IN_SECONDS = 86_400

  Result = Struct.new(:deactivated, :skipped, :errors, keyword_init: true)

  def self.call(client:, grace_days: 7, collect_payment: true)
    new(client: client, grace_days: grace_days, collect_payment: collect_payment).call
  end

  attr_reader :client, :grace_days, :collect_payment

  def initialize(client:, grace_days: 7, collect_payment: true)
    @client = client
    @grace_days = grace_days
    @collect_payment = collect_payment
  end

  def call
    result = Result.new(deactivated: [], skipped: [], errors: [])
    now = Time.now.to_i

    candidates = select_candidates(now)
    return log_summary(result) if candidates.empty?

    member_ids = client.user_id_to_member_id_map

    candidates.each do |user|
      process_candidate(user, member_ids, result)
    end

    log_summary(result)
  end

  private

  def select_candidates(now)
    users = client.list_users
    plans_by_user = client.list_account_plans.group_by { |p| p.dig("access_usage_user", "user_id") }
    cutoff = now - (grace_days * DAY_IN_SECONDS)

    users.select do |user|
      next false unless user["is_active"]
      next false if user["is_admin"]
      next false if user["has_plans"]

      user_plans = plans_by_user[user["user_id"]] || []
      next false if user_plans.empty?
      next false if user_plans.any? { |p| ACTIVE_PLAN_STATUSES.include?(p["status"]) }

      last_end = last_membership_end(user_plans, now)
      next false if last_end.nil?

      last_end <= cutoff
    end
  end

  # When did this user's membership actually lapse? Only plans that started
  # count; effective end is end_timestamp, else canceled_timestamp. nil when
  # no plan ever ran or no end data exists (caller skips — conservative).
  def last_membership_end(user_plans, now)
    started = user_plans.select { |p| p["start_timestamp"] && p["start_timestamp"] <= now }
    started.map { |p| p["end_timestamp"] || p["canceled_timestamp"] }.compact.max
  end

  def process_candidate(user, member_ids, result)
    user_id = user["user_id"]
    member_id = member_ids[user_id]

    if member_id.nil?
      result.skipped << skip(user, "no member_id mapping (no invoices on record)")
      return
    end

    begin
      preview = client.member_remove_preview(member_id)
    rescue Stacks::Optix::ApiError => e
      result.skipped << skip(user, "memberRemovePreview failed: #{e.message}")
      return
    end

    begin
      client.member_remove!(member_id, collect_payment: collect_payment)
    rescue => e
      result.errors << { user_id: user_id, email: user["email"], error: "#{e.class}: #{e.message}" }
      Rails.logger.error("[#{self.class.name}] memberRemove failed for #{user["email"]} (member_id=#{member_id}): #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      return
    end

    entry = {
      user_id: user_id,
      member_id: member_id,
      email: user["email"],
      name: [user["name"], user["surname"]].compact.join(" "),
      invoice_total: preview && preview["total"],
    }
    result.deactivated << entry
    Rails.logger.info("[#{self.class.name}] deactivated #{entry[:email]} (user_id=#{user_id}, member_id=#{member_id}, invoice_total=#{entry[:invoice_total]})")
  end

  def skip(user, reason)
    Rails.logger.warn("[#{self.class.name}] skipped #{user["email"]} (user_id=#{user["user_id"]}): #{reason}")
    { user_id: user["user_id"], email: user["email"], reason: reason }
  end

  def log_summary(result)
    Rails.logger.info(
      "[#{self.class.name}] done: #{result.deactivated.length} deactivated, " \
      "#{result.skipped.length} skipped, #{result.errors.length} errored"
    )
    result
  end
end
```

In `lib/stacks/optix.rb`, add directly after the `initialize` method:

```ruby
  # Daily automation entrypoint (called from Enterprise#daily_tasks for Index).
  # Uses OptixOrganization.first — consistent with the single-tenant assumption
  # documented on OptixOrganization and in stacks.rake.
  def self.deactivate_inactive_members!(grace_days: 7, collect_payment: true)
    Stacks::Optix::DeactivateInactiveMembers.call(
      client: new(OptixOrganization.first),
      grace_days: grace_days,
      collect_payment: collect_payment,
    )
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/lib/stacks/optix/deactivate_inactive_members_test.rb test/lib/stacks/optix_test.rb`
Expected: PASS (all)

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/optix.rb lib/stacks/optix/deactivate_inactive_members.rb test/lib/stacks/optix/deactivate_inactive_members_test.rb
git commit -m "feat(optix): DeactivateInactiveMembers service with validated selection rules"
```

---

### Task 3: `Enterprise#is_index?` and `#daily_tasks`

**Files:**
- Modify: `app/models/enterprise.rb` (add after the `self.garden3d` class method, ~line 58)
- Modify: `test/models/enterprise_test.rb` (append a new test class at the end)

**Interfaces:**
- Consumes (from Task 2): `Stacks::Optix.deactivate_inactive_members!`
- Produces (used by Task 4): `Enterprise#daily_tasks` (returns the service Result for Index, nil otherwise)

- [ ] **Step 1: Write the failing tests**

Append to `test/models/enterprise_test.rb`:

```ruby
class EnterpriseDailyTasksTest < ActiveSupport::TestCase
  test "is_index? is true only for Index Space, LLC" do
    index = Enterprise.find_or_create_by!(name: Enterprise::INDEX_SPACE_NAME)
    other = Enterprise.create!(name: "Some Other Enterprise #{SecureRandom.hex(4)}")
    assert index.is_index?
    refute other.is_index?
  end

  test "daily_tasks deactivates inactive Optix members for Index" do
    index = Enterprise.find_or_create_by!(name: Enterprise::INDEX_SPACE_NAME)
    Stacks::Optix.expects(:deactivate_inactive_members!).once
    index.daily_tasks
  end

  test "daily_tasks is a no-op for non-Index enterprises" do
    other = Enterprise.create!(name: "Some Other Enterprise #{SecureRandom.hex(4)}")
    Stacks::Optix.expects(:deactivate_inactive_members!).never
    other.daily_tasks
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/enterprise_test.rb`
Expected: FAIL — `NoMethodError: undefined method 'is_index?'`

- [ ] **Step 3: Implement**

In `app/models/enterprise.rb`, after `self.garden3d`:

```ruby
  def is_index?
    name == INDEX_SPACE_NAME
  end

  # Per-enterprise daily automation, dispatched by stacks:daily_enterprise_tasks.
  # Add new per-enterprise behaviors here rather than as new rake steps.
  def daily_tasks
    Stacks::Optix.deactivate_inactive_members! if is_index?
  end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/enterprise_test.rb`
Expected: PASS (all, including pre-existing tests)

- [ ] **Step 5: Commit**

```bash
git add app/models/enterprise.rb test/models/enterprise_test.rb
git commit -m "feat(enterprise): per-enterprise daily_tasks with Optix deactivation for Index"
```

---

### Task 4: Rake hook in `stacks:daily_enterprise_tasks`

**Files:**
- Modify: `lib/tasks/stacks.rake` — inside the `:daily_enterprise_tasks` task, after the "Auto-flipped legacy ledger(s)" block (ends ~line 112, right before the `rescue => e` of the task)

**Interfaces:**
- Consumes (from Task 3): `Enterprise#daily_tasks`
- Produces: nothing downstream

- [ ] **Step 1: Implement (thin glue — covered by the Task 3 model tests; the rake step follows the task's existing per-item isolation pattern verbatim)**

Add after the legacy-ledger auto-flip block:

```ruby
      # Per-enterprise daily automations (e.g. Optix inactive-member
      # deactivation for Index). Per-enterprise errors are isolated so one
      # enterprise's failure doesn't block the others.
      Enterprise.find_each do |e|
        e.daily_tasks
      rescue => err
        Rails.logger.error("[stacks:daily_enterprise_tasks] Enterprise##{e.id} (#{e.name}) daily_tasks failed: #{err.class}: #{err.message}")
        Sentry.capture_exception(err) if defined?(Sentry)
      end
```

- [ ] **Step 2: Verify the rake file parses and the task loads**

Run: `bin/rails runner 'Rails.application.load_tasks; puts Rake::Task["stacks:daily_enterprise_tasks"].name'`
Expected: prints `stacks:daily_enterprise_tasks` with no errors

- [ ] **Step 3: Commit**

```bash
git add lib/tasks/stacks.rake
git commit -m "feat(rake): dispatch per-enterprise daily_tasks in daily_enterprise_tasks"
```

---

### Task 5: Teach `OptixOrganization` analytics that UPCOMING is membership

**Files:**
- Modify: `app/models/optix_organization.rb` (`active_members` ~line 25, `inactive_members` ~line 38)
- Create: `test/models/optix_organization_test.rb`

**Interfaces:**
- Consumes: nothing from other tasks (independent)
- Produces: corrected `OptixOrganization#active_members` / `#inactive_members` semantics (admin dashboard analytics)

- [ ] **Step 1: Write the failing tests**

Create `test/models/optix_organization_test.rb`:

```ruby
require "test_helper"

class OptixOrganizationMembershipTest < ActiveSupport::TestCase
  setup do
    @org = OptixOrganization.create!(name: "Test Org #{SecureRandom.hex(4)}")
  end

  def make_user(id)
    OptixUser.create!(optix_id: id, optix_organization_id: @org.id, email: "#{id}@example.com")
  end

  def make_plan(user_optix_id, status:)
    OptixAccountPlan.create!(
      optix_id: SecureRandom.hex(6),
      optix_organization_id: @org.id,
      status: status,
      access_usage_user_optix_id: user_optix_id,
    )
  end

  test "a user with an UPCOMING plan is an active member, not churned" do
    upcoming = make_user("u-upcoming")
    make_plan("u-upcoming", status: "UPCOMING")

    churned = make_user("u-churned")
    make_plan("u-churned", status: "ENDED")

    assert_includes @org.active_members, upcoming
    refute_includes @org.inactive_members, upcoming
    assert_includes @org.inactive_members, churned
    refute_includes @org.active_members, churned
  end

  test "ACTIVE and IN_TRIAL still count as membership" do
    active = make_user("u-active")
    make_plan("u-active", status: "ACTIVE")
    trial = make_user("u-trial")
    make_plan("u-trial", status: "IN_TRIAL")

    assert_includes @org.active_members, active
    assert_includes @org.active_members, trial
    assert_empty @org.inactive_members
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/rails test test/models/optix_organization_test.rb`
Expected: FAIL — the UPCOMING user appears in `inactive_members` and not in `active_members`

- [ ] **Step 3: Implement**

In `app/models/optix_organization.rb`, add a constant above `active_members` and use it in both methods:

```ruby
  # Plan statuses that constitute current membership. UPCOMING (a scheduled
  # future plan) counts — a member with a booked return date has not churned.
  # NOTE: plans held through a team don't appear in optix_account_plans for
  # the member, so these DB-backed rosters can still slightly overcount churn;
  # the deactivation automation (Stacks::Optix::DeactivateInactiveMembers)
  # additionally checks Optix's has_plans flag via the live API.
  MEMBERSHIP_PLAN_STATUSES = %w[ACTIVE IN_TRIAL UPCOMING].freeze
```

In `active_members`, change:

```ruby
      .where(optix_account_plans: { status: %w[ACTIVE IN_TRIAL] })
```

to:

```ruby
      .where(optix_account_plans: { status: MEMBERSHIP_PLAN_STATUSES })
```

In `inactive_members`, change:

```ruby
    user_ids_with_active_plans = optix_account_plans
      .where(status: %w[ACTIVE IN_TRIAL])
```

to:

```ruby
    user_ids_with_active_plans = optix_account_plans
      .where(status: MEMBERSHIP_PLAN_STATUSES)
```

Also update the two comment lines above those methods that say "ACTIVE or IN_TRIAL" to say "ACTIVE, IN_TRIAL, or UPCOMING".

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/rails test test/models/optix_organization_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/models/optix_organization.rb test/models/optix_organization_test.rb
git commit -m "fix(optix): UPCOMING plans count as membership in churn analytics"
```

---

### Task 6: Full-suite verification

- [ ] **Step 1: Run the entire test suite**

Run: `bin/rails test`
Expected: 0 failures, 0 errors (same skip count as main, if any)

- [ ] **Step 2: Eager-load check (Zeitwerk naming)**

Run: `bin/rails runner 'Rails.application.eager_load!; puts Stacks::Optix::DeactivateInactiveMembers.name'`
Expected: prints `Stacks::Optix::DeactivateInactiveMembers`

- [ ] **Step 3: Commit anything outstanding, if needed**
