# Permission Grants (Lead-in-Training Access) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let admins grant lead-equivalent ActiveAdmin access to people who have never held a lead period, globally or scoped (read-only) to specific projects, via a new extensible `permission_grants` table.

**Architecture:** A `PermissionGrant` row is `{admin_user, permission, optional polymorphic subject, granted_by, notes}`. A global `"lead"` grant (no subject) makes `AdminUser#can_act_as_lead?` true, which replaces `has_led_projects?` at the master gate in `AdminAuthorization#authorized?`. A project-scoped grant (subject = a `ProjectTracker`) does NOT pass that gate; instead new adapter rules allow read-only access to the granted ProjectTrackers and the InvoiceTrackers billing them, and a new `scope_collection` implementation filters those two index pages.

**Tech Stack:** Rails 6.1, Ruby 3.1.7, PostgreSQL (jsonb), ActiveAdmin 2.9 (custom `AuthorizationAdapter`), minitest + mocha, Devise integration-test helpers.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-04-permission-grants-design.md`.
- `AdminUser#has_led_projects?` keeps its exact current meaning (has actually held an `AccountLeadPeriod`/`ProjectLeadPeriod`); authorization call sites move to the new `can_act_as_lead?`.
- Never touch `AccountLeadPeriod`/`ProjectLeadPeriod` data or models (they drive compensation).
- `PermissionGrant::PERMISSIONS = %w[lead]` and `SUBJECT_TYPES = %w[ProjectTracker]` are the only allow-lists; extending the system later means adding strings there.
- Scoped grants are strictly read-only (`:read` only — ActiveAdmin maps index/show to `:read`; custom member actions pass through verbatim and must stay denied).
- Tests run with `bin/rails test <path>`. The full suite must pass before the PR.
- Commit messages end with: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Working dir: `/Users/hhff/Documents/Code/stacks/.claude/worktrees/per-project-stacks-permissions` (branch `worktree-per-project-stacks-permissions`).

---

### Task 1: PermissionGrant model + migration

**Files:**
- Create: `db/migrate/20260804000001_create_permission_grants.rb`
- Create: `app/models/permission_grant.rb`
- Test: `test/models/permission_grant_test.rb`

**Interfaces:**
- Produces: `PermissionGrant` (AR model) with `PERMISSIONS`, `SUBJECT_TYPES` constants; associations `admin_user`, `granted_by` (AdminUser, optional), `subject` (polymorphic, optional); scopes `.global`, `.for_permission(p)`; predicate `#global?`. Auto-defaults `subject_type` to `"ProjectTracker"` when only `subject_id` is given.

- [ ] **Step 1: Write the failing test**

Create `test/models/permission_grant_test.rb`:

```ruby
require 'test_helper'

class PermissionGrantTest < ActiveSupport::TestCase
  def make_user(email)
    AdminUser.create!(email: email, password: "password12345")
  end

  test "a global lead grant is valid and global?" do
    user = make_user("trainee@sanctuary.computer")
    granter = make_user("granter@sanctuary.computer")
    grant = PermissionGrant.create!(admin_user: user, permission: "lead", granted_by: granter)
    assert grant.global?
    assert_includes PermissionGrant.global.for_permission("lead"), grant
  end

  test "permission must be in the allow-list" do
    user = make_user("trainee@sanctuary.computer")
    grant = PermissionGrant.new(admin_user: user, permission: "superuser")
    refute grant.valid?
    assert grant.errors[:permission].any?
  end

  test "subject_type defaults to ProjectTracker when only subject_id is set" do
    user = make_user("trainee@sanctuary.computer")
    pt = ProjectTracker.create!(name: "Some Project")
    grant = PermissionGrant.create!(admin_user: user, permission: "lead", subject_id: pt.id)
    assert_equal "ProjectTracker", grant.subject_type
    assert_equal pt, grant.subject
    refute grant.global?
  end

  test "duplicate grants are rejected" do
    user = make_user("trainee@sanctuary.computer")
    PermissionGrant.create!(admin_user: user, permission: "lead")
    dup = PermissionGrant.new(admin_user: user, permission: "lead")
    refute dup.valid?

    pt = ProjectTracker.create!(name: "Some Project")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt)
    scoped_dup = PermissionGrant.new(admin_user: user, permission: "lead", subject: pt)
    refute scoped_dup.valid?
  end

  test "subject_type outside the allow-list is rejected" do
    user = make_user("trainee@sanctuary.computer")
    grant = PermissionGrant.new(admin_user: user, permission: "lead", subject_type: "Studio", subject_id: 1)
    refute grant.valid?
    assert grant.errors[:subject_type].any?
  end
end
```

If `ProjectTracker.create!(name: ...)` fails a model validation, inspect `app/models/project_tracker.rb` validations and add the minimal required attributes — do not stub.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/permission_grant_test.rb`
Expected: FAIL/ERROR with `uninitialized constant PermissionGrant`

- [ ] **Step 3: Write migration and model**

Create `db/migrate/20260804000001_create_permission_grants.rb`:

```ruby
class CreatePermissionGrants < ActiveRecord::Migration[6.1]
  def change
    create_table :permission_grants do |t|
      t.references :admin_user, null: false, foreign_key: true
      t.string :permission, null: false
      t.string :subject_type
      t.bigint :subject_id
      t.references :granted_by, foreign_key: { to_table: :admin_users }
      t.text :notes
      t.timestamps
    end

    add_index :permission_grants, [:subject_type, :subject_id]
    add_index :permission_grants, [:admin_user_id, :permission],
      unique: true,
      where: "subject_type IS NULL AND subject_id IS NULL",
      name: "index_permission_grants_unique_global"
    add_index :permission_grants, [:admin_user_id, :permission, :subject_type, :subject_id],
      unique: true,
      where: "subject_id IS NOT NULL",
      name: "index_permission_grants_unique_scoped"
  end
end
```

Create `app/models/permission_grant.rb`:

```ruby
# An explicit, admin-granted permission for an AdminUser. A grant with no
# subject is global (e.g. a lead-in-training who should see everything a
# real lead sees); a grant with a subject narrows the permission to that
# record. Extend PERMISSIONS / SUBJECT_TYPES to add new kinds — the shape
# needs no schema change.
class PermissionGrant < ApplicationRecord
  PERMISSIONS = %w[lead].freeze
  SUBJECT_TYPES = %w[ProjectTracker].freeze

  belongs_to :admin_user
  belongs_to :granted_by, class_name: "AdminUser", optional: true
  belongs_to :subject, polymorphic: true, optional: true

  before_validation do
    self.subject_type = "ProjectTracker" if subject_id.present? && subject_type.blank?
    self.subject_type = nil if subject_id.blank?
  end

  validates :permission, inclusion: { in: PERMISSIONS }
  validates :subject_type, inclusion: { in: SUBJECT_TYPES }, allow_nil: true
  validates :permission, uniqueness: { scope: [:admin_user_id, :subject_type, :subject_id] }

  scope :global, -> { where(subject_type: nil, subject_id: nil) }
  scope :for_permission, ->(p) { where(permission: p) }

  def global?
    subject_type.nil? && subject_id.nil?
  end
end
```

If the repo has no `ApplicationRecord` (check `app/models/application_record.rb`), inherit from `ActiveRecord::Base` like the model next to it (`app/models/account_lead_period.rb`) does.

- [ ] **Step 4: Migrate and run the test**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bin/rails test test/models/permission_grant_test.rb`
Expected: PASS (all 5 tests). `db/schema.rb` will be updated by the migration — commit that too.

- [ ] **Step 5: Commit**

```bash
git add db/migrate/20260804000001_create_permission_grants.rb db/schema.rb app/models/permission_grant.rb test/models/permission_grant_test.rb
git commit -m "feat: PermissionGrant model — extensible admin-granted permissions

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: AdminUser predicates + ProjectTracker association

**Files:**
- Modify: `app/models/admin_user.rb` (associations block near the top ~line 1-30; predicates near `has_led_projects?` at ~line 556)
- Modify: `app/models/project_tracker.rb` (associations block ~line 42-60)
- Test: `test/models/admin_user_permission_grants_test.rb`

**Interfaces:**
- Consumes: `PermissionGrant` from Task 1.
- Produces: `AdminUser#can_act_as_lead?` → Boolean; `AdminUser#lead_scoped_project_tracker_ids` → Array<Integer>; `AdminUser` `has_many :permission_grants` (+ `accepts_nested_attributes_for ... allow_destroy: true`); `ProjectTracker has_many :permission_grants, as: :subject, dependent: :destroy`.

- [ ] **Step 1: Write the failing test**

Create `test/models/admin_user_permission_grants_test.rb`:

```ruby
require 'test_helper'

class AdminUserPermissionGrantsTest < ActiveSupport::TestCase
  def make_user(email)
    AdminUser.create!(email: email, password: "password12345")
  end

  test "can_act_as_lead? is true for someone who actually led a project" do
    user = make_user("led@sanctuary.computer")
    pt = ProjectTracker.create!(name: "Led Project")
    ProjectLeadPeriod.create!(project_tracker: pt, admin_user: user,
      started_at: Date.new(2025, 1, 1), ended_at: Date.new(2025, 3, 31))
    assert user.can_act_as_lead?
  end

  test "can_act_as_lead? is true with a global lead grant and false otherwise" do
    user = make_user("trainee@sanctuary.computer")
    refute user.can_act_as_lead?
    PermissionGrant.create!(admin_user: user, permission: "lead")
    assert user.reload.can_act_as_lead?
  end

  test "a project-scoped grant does NOT make can_act_as_lead? true, but appears in lead_scoped_project_tracker_ids" do
    user = make_user("scoped@sanctuary.computer")
    pt = ProjectTracker.create!(name: "Scoped Project")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt)
    refute user.can_act_as_lead?
    assert_equal [pt.id], user.lead_scoped_project_tracker_ids
  end

  test "destroying a project tracker destroys grants scoped to it" do
    user = make_user("scoped@sanctuary.computer")
    pt = ProjectTracker.create!(name: "Doomed Project")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt)
    pt.destroy!
    assert_equal [], user.reload.permission_grants
  end

  test "destroying a user destroys their grants" do
    user = make_user("leaving@sanctuary.computer")
    grant = PermissionGrant.create!(admin_user: user, permission: "lead")
    user.destroy!
    refute PermissionGrant.exists?(grant.id)
  end
end
```

If `ProjectLeadPeriod.create!` fails validation (it validates full-month periods), keep `started_at` on the 1st and `ended_at` on the last day of a month as shown.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/admin_user_permission_grants_test.rb`
Expected: FAIL with `undefined method 'can_act_as_lead?'`

- [ ] **Step 3: Implement**

In `app/models/admin_user.rb`, add to the association block at the top of the class (after `has_many :enterprise_admins, dependent: :destroy`):

```ruby
  has_many :permission_grants, dependent: :destroy
  accepts_nested_attributes_for :permission_grants, allow_destroy: true
```

Directly below `has_led_projects?` (~line 556), add:

```ruby
  # Lead-level ActiveAdmin access: either they've actually held a lead
  # period, or an admin granted them global "lead" permission (a
  # lead-in-training). Scoped grants deliberately don't count here.
  def can_act_as_lead?
    has_led_projects? || permission_grants.global.for_permission("lead").any?
  end

  # ProjectTracker ids this user may read via project-scoped "lead" grants.
  def lead_scoped_project_tracker_ids
    permission_grants.for_permission("lead").where(subject_type: "ProjectTracker").pluck(:subject_id)
  end
```

In `app/models/project_tracker.rb`, add after the `project_lead_periods` associations (~line 60):

```ruby
  has_many :permission_grants, as: :subject, dependent: :destroy
```

- [ ] **Step 4: Run tests**

Run: `bin/rails test test/models/admin_user_permission_grants_test.rb test/models/permission_grant_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/models/admin_user.rb app/models/project_tracker.rb test/models/admin_user_permission_grants_test.rb
git commit -m "feat: AdminUser#can_act_as_lead? + scoped grant lookup

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: AdminAuthorization — global gate swap, scoped read rules, index scoping

**Files:**
- Modify: `app/models/admin_authorization.rb` (replace commented-out `scope_collection` at lines 15-24; edit gate at line 35; insert scoped-rules block after it)
- Modify: `app/views/admin/contributor_payouts/_show.html.erb:9` (`has_led_projects?` → `can_act_as_lead?`)
- Test: `test/models/admin_authorization_test.rb`

**Interfaces:**
- Consumes: `AdminUser#can_act_as_lead?`, `#lead_scoped_project_tracker_ids` (Task 2).
- Produces: `AdminAuthorization#authorized?(action, subject)` honoring grants; `AdminAuthorization#scope_collection(collection, action = :read)` filtering `ProjectTracker` / `InvoiceTracker` relations for scoped-only users. (ActiveAdmin's `apply_authorization_scope` calls `scope_collection` on every index automatically — data_access.rb `COLLECTION_APPLIES` — so no controller changes are needed.)

- [ ] **Step 1: Write the failing test**

Create `test/models/admin_authorization_test.rb`:

```ruby
require 'test_helper'

class AdminAuthorizationTest < ActiveSupport::TestCase
  def auth_for(user)
    AdminAuthorization.new(nil, user)
  end

  def make_user(email)
    AdminUser.create!(email: email, password: "password12345")
  end

  test "a user with no grants and no lead history has no ProjectTracker access" do
    user = make_user("nobody@sanctuary.computer")
    refute auth_for(user).authorized?(:read, ProjectTracker)
  end

  test "a global lead grant confers the same blanket access as having led" do
    user = make_user("trainee@sanctuary.computer")
    PermissionGrant.create!(admin_user: user, permission: "lead")
    auth = auth_for(user)
    assert auth.authorized?(:read, ProjectTracker)
    assert auth.authorized?(:update, ProjectTracker.new)
    assert auth.authorized?(:read, InvoiceTracker)
    assert auth.authorized?(:read, Studio)
  end

  test "a project-scoped grant gives read-only access to that project" do
    user = make_user("scoped@sanctuary.computer")
    pt_mine = ProjectTracker.create!(name: "Mine")
    pt_other = ProjectTracker.create!(name: "Other")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt_mine)

    auth = auth_for(user)
    # class-level reads so menus and index pages render
    assert auth.authorized?(:read, ProjectTracker)
    assert auth.authorized?(:read, InvoiceTracker)
    assert auth.authorized?(:read, InvoicePass)
    # record-level reads limited to the granted project
    assert auth.authorized?(:read, pt_mine)
    refute auth.authorized?(:read, pt_other)
    # strictly read-only
    refute auth.authorized?(:update, pt_mine)
    refute auth.authorized?(:destroy, pt_mine)
    refute auth.authorized?(:create, ProjectTracker)
    # no blanket access to anything else
    refute auth.authorized?(:read, Studio)
  end

  test "scoped grant allows reading only invoice trackers billing the granted project" do
    user = make_user("scoped2@sanctuary.computer")
    pt = ProjectTracker.create!(name: "Mine")
    fp = ForecastProject.create!(name: "Mine FP", code: "MINE-1")
    other_fp = ForecastProject.create!(name: "Other FP", code: "OTHR-1")
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: fp)
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt)

    in_scope = InvoiceTracker.new(blueprint: { "lines" => { "0" => { "forecast_project" => fp.id } } })
    out_of_scope = InvoiceTracker.new(blueprint: { "lines" => { "0" => { "forecast_project" => other_fp.id } } })

    auth = auth_for(user)
    assert auth.authorized?(:read, in_scope)
    refute auth.authorized?(:read, out_of_scope)
    refute auth.authorized?(:toggle_ownership, in_scope)
  end

  test "scope_collection filters ProjectTracker index to granted projects" do
    user = make_user("scoped3@sanctuary.computer")
    pt_mine = ProjectTracker.create!(name: "Mine")
    ProjectTracker.create!(name: "Other")
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt_mine)

    assert_equal [pt_mine.id], auth_for(user).scope_collection(ProjectTracker.all).pluck(:id)
  end

  test "scope_collection filters InvoiceTracker index via blueprint forecast projects" do
    user = make_user("scoped4@sanctuary.computer")
    pt = ProjectTracker.create!(name: "Mine")
    fp = ForecastProject.create!(name: "Mine FP", code: "MINE-2")
    other_fp = ForecastProject.create!(name: "Other FP", code: "OTHR-2")
    ProjectTrackerForecastProject.create!(project_tracker: pt, forecast_project: fp)
    PermissionGrant.create!(admin_user: user, permission: "lead", subject: pt)

    ip = InvoicePass.create!(start_of_month: Date.new(2031, 1, 1))
    fc_mine = ForecastClient.create!(forecast_id: 910001, name: "Client Mine")
    fc_other = ForecastClient.create!(forecast_id: 910002, name: "Client Other")
    qbo = qbo_accounts(:one)
    it_mine = InvoiceTracker.create!(forecast_client: fc_mine, invoice_pass: ip, qbo_account: qbo,
      blueprint: { "lines" => { "0" => { "forecast_project" => fp.id } } })
    InvoiceTracker.create!(forecast_client: fc_other, invoice_pass: ip, qbo_account: qbo,
      blueprint: { "lines" => { "0" => { "forecast_project" => other_fp.id } } })
    InvoiceTracker.create!(forecast_client: ForecastClient.create!(forecast_id: 910003, name: "Nil BP"),
      invoice_pass: ip, qbo_account: qbo, blueprint: nil)

    assert_equal [it_mine.id], auth_for(user).scope_collection(InvoiceTracker.all).pluck(:id)
  end

  test "scope_collection leaves collections untouched for admins, leads, and unrelated classes" do
    admin = make_user("adm@sanctuary.computer")
    admin.update!(roles: ["admin"])
    lead_grantee = make_user("gl@sanctuary.computer")
    PermissionGrant.create!(admin_user: lead_grantee, permission: "lead")
    ProjectTracker.create!(name: "A")

    assert_equal ProjectTracker.count, auth_for(admin).scope_collection(ProjectTracker.all).count
    assert_equal ProjectTracker.count, auth_for(lead_grantee).scope_collection(ProjectTracker.all).count

    scoped = make_user("sc@sanctuary.computer")
    PermissionGrant.create!(admin_user: scoped, permission: "lead", subject: ProjectTracker.first)
    assert_equal AdminUser.count, auth_for(scoped).scope_collection(AdminUser.all).count
  end

  test "existing contributor fallback rules still work for users without grants" do
    user = make_user("plain@sanctuary.computer")
    auth = auth_for(user)
    assert auth.authorized?(:read, user)          # own AdminUser record
    assert auth.authorized?(:read, Survey)
    refute auth.authorized?(:read, InvoiceTracker)
  end
end
```

Adjust record creation only if a model validation demands another attribute (e.g. `InvoiceTracker` uniqueness on `[forecast_client_id, invoice_pass_id]` is why each tracker gets its own client). Do not weaken assertions.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/models/admin_authorization_test.rb`
Expected: the global-grant, scoped, and scope_collection tests FAIL (adapter still checks `has_led_projects?` and has no `scope_collection`).

- [ ] **Step 3: Implement the adapter changes**

In `app/models/admin_authorization.rb`:

**(a)** Replace the commented-out `scope_collection` block (lines 15-24) with:

```ruby
  # Narrows index pages for users whose only access comes from
  # project-scoped "lead" grants. Admins and (actual or granted) leads see
  # everything. ActiveAdmin calls this automatically for every index via
  # apply_authorization_scope.
  def scope_collection(collection, action = :read)
    return collection if user.is_admin? || user.can_act_as_lead?

    scoped_ids = user.lead_scoped_project_tracker_ids
    return collection if scoped_ids.empty?

    case collection.klass.name
    when "ProjectTracker"
      collection.where(id: scoped_ids)
    when "InvoiceTracker"
      forecast_project_ids = ProjectTrackerForecastProject
        .where(project_tracker_id: scoped_ids)
        .pluck(:forecast_project_id)
      return collection.none if forecast_project_ids.empty?

      collection.where(<<~SQL.squish, forecast_project_ids)
        invoice_trackers.blueprint IS NOT NULL
        AND jsonb_typeof(invoice_trackers.blueprint -> 'lines') = 'object'
        AND EXISTS (
          SELECT 1
          FROM jsonb_each(invoice_trackers.blueprint -> 'lines') AS line
          WHERE (line.value ->> 'forecast_project')::bigint IN (?)
        )
      SQL
    else
      collection
    end
  end
```

**(b)** Change line 35 from

```ruby
    return true if (user.is_admin? || user.has_led_projects?)
```

to

```ruby
    return true if (user.is_admin? || user.can_act_as_lead?)
```

**(c)** Immediately after that line, insert:

```ruby
    # Project-scoped "lead" grants (leads-in-training limited to specific
    # projects): read-only visibility into the granted ProjectTrackers, the
    # InvoiceTrackers that bill them, and the InvoicePass containers needed
    # to navigate to those trackers. scope_collection narrows the index
    # pages; this handles class-level (menu/index) and per-record checks.
    if action == :read
      scoped_ids = user.lead_scoped_project_tracker_ids
      if scoped_ids.any?
        return true if [ProjectTracker, InvoiceTracker, InvoicePass].include?(subject)
        return true if subject.is_a?(InvoicePass)
        return true if subject.is_a?(ProjectTracker) && scoped_ids.include?(subject.id)
        return true if subject.is_a?(InvoiceTracker) && (subject.project_trackers.map(&:id) & scoped_ids).any?
      end
    end
```

**(d)** In `app/views/admin/contributor_payouts/_show.html.erb` line 9, change `current_admin_user.has_led_projects?` to `current_admin_user.can_act_as_lead?`.

- [ ] **Step 4: Run the adapter tests, then the model tests from Tasks 1-2**

Run: `bin/rails test test/models/admin_authorization_test.rb test/models/permission_grant_test.rb test/models/admin_user_permission_grants_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/models/admin_authorization.rb app/views/admin/contributor_payouts/_show.html.erb test/models/admin_authorization_test.rb
git commit -m "feat: honor permission grants in AdminAuthorization (global + project-scoped read-only)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Admin UI — grant management on AdminUser + guard promote/demote

**Files:**
- Modify: `app/admin/admin_users.rb` (permit_params ~line 2-33; member_actions ~line 75-83; controller block ~line 85; form ~line 197-201)
- Modify: `app/views/admin/admin_users/_show.html.erb` (append Permission Grants panel)
- Test: `test/integration/admin_permission_grants_test.rb`

**Interfaces:**
- Consumes: `PermissionGrant::PERMISSIONS`, `AdminUser accepts_nested_attributes_for :permission_grants` (Tasks 1-2).
- Produces: admin-only nested form + show panel for grants; `granted_by` stamped server-side; `promote_admin_user`/`demote_admin_user` gated by `current_admin_user.is_admin?`.

- [ ] **Step 1: Write the failing test**

Create `test/integration/admin_permission_grants_test.rb`:

```ruby
require 'test_helper'

class AdminPermissionGrantsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = AdminUser.create!(
      email: "hugh@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345',
      roles: ['admin']
    )
    @trainee = AdminUser.create!(
      email: "trainee@sanctuary.computer",
      password: 'password12345', password_confirmation: 'password12345'
    )
  end

  test "an admin can create a global lead grant from the edit form" do
    sign_in @admin
    put admin_admin_user_path(@trainee), params: {
      admin_user: {
        permission_grants_attributes: {
          "0" => { permission: "lead", subject_id: "", notes: "AL training" }
        }
      }
    }
    assert_equal 1, @trainee.reload.permission_grants.count
    grant = @trainee.permission_grants.first
    assert grant.global?
    assert_equal @admin.id, grant.granted_by_id
    assert @trainee.can_act_as_lead?
  end

  test "an admin can create a project-scoped grant" do
    pt = ProjectTracker.create!(name: "Training Project")
    sign_in @admin
    put admin_admin_user_path(@trainee), params: {
      admin_user: {
        permission_grants_attributes: {
          "0" => { permission: "lead", subject_id: pt.id.to_s }
        }
      }
    }
    grant = @trainee.reload.permission_grants.first
    assert_equal pt, grant.subject
    refute @trainee.can_act_as_lead?
    assert_equal [pt.id], @trainee.lead_scoped_project_tracker_ids
  end

  test "a non-admin (even a global grantee) cannot create grants" do
    PermissionGrant.create!(admin_user: @trainee, permission: "lead", granted_by: @admin)
    sign_in @trainee
    put admin_admin_user_path(@trainee), params: {
      admin_user: {
        profit_share_notes: "hi",
        permission_grants_attributes: {
          "0" => { permission: "lead", subject_id: "", notes: "sneaky second grant" }
        }
      }
    }
    assert_equal 1, @trainee.reload.permission_grants.count
  end

  test "a non-admin lead cannot promote themselves to admin" do
    PermissionGrant.create!(admin_user: @trainee, permission: "lead", granted_by: @admin)
    sign_in @trainee
    post promote_admin_user_admin_admin_user_path(@trainee)
    refute @trainee.reload.is_admin?
  end

  test "a non-admin lead cannot demote an admin" do
    PermissionGrant.create!(admin_user: @trainee, permission: "lead", granted_by: @admin)
    sign_in @trainee
    post demote_admin_user_admin_admin_user_path(@admin)
    assert @admin.reload.is_admin?
  end

  test "an admin can still promote and demote" do
    sign_in @admin
    post promote_admin_user_admin_admin_user_path(@trainee)
    assert @trainee.reload.is_admin?
    post demote_admin_user_admin_admin_user_path(@trainee)
    refute @trainee.reload.is_admin?
  end

  test "the show page lists grants for admins" do
    PermissionGrant.create!(admin_user: @trainee, permission: "lead", granted_by: @admin, notes: "Q3 cohort")
    sign_in @admin
    get admin_admin_user_path(@trainee)
    assert_response :success
    assert_includes response.body, "Permission Grants"
    assert_includes response.body, "Q3 cohort"
  end
end
```

Note: `@admin` demoting/promoting relies on `is_admin?` including the `is_hugh?` email backdoor — that's why `@admin` uses Hugh's email AND `roles: ['admin']` (the demote test targets `@trainee`, not `@admin`).

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/admin_permission_grants_test.rb`
Expected: FAIL — grants not created (param not permitted), promote test FAILS because the trainee CAN currently self-promote (this failure proves the live escalation hole), show page lacks the panel.

- [ ] **Step 3: Implement**

In `app/admin/admin_users.rb`:

**(a)** Append to `permit_params` (after `pre_profit_share_purchases_attributes`):

```ruby
    permission_grants_attributes: [
      :id,
      :permission,
      :subject_id,
      :notes,
      :granted_by_id,
      :_destroy
    ]
```

**(b)** Replace the two unguarded member_actions (lines 75-83) with:

```ruby
  member_action :demote_admin_user, method: :post do
    unless current_admin_user.is_admin?
      redirect_to admin_admin_user_path(resource), alert: "Only admins can do that."
      return
    end
    resource.update!(roles: [])
    redirect_to admin_admin_user_path(resource), notice: "Success!"
  end

  member_action :promote_admin_user, method: :post do
    unless current_admin_user.is_admin?
      redirect_to admin_admin_user_path(resource), alert: "Only admins can do that."
      return
    end
    resource.update!(roles: ["admin"])
    redirect_to admin_admin_user_path(resource), notice: "Success!"
  end
```

**(c)** Inside the existing `controller do` block, add:

```ruby
    # Permission grants are admin-managed only. The form hides them from
    # non-admins, but leads pass the authorization adapter for AdminUser
    # updates, so strip the params server-side too. New grants get
    # granted_by stamped from the acting admin, never from the client.
    def update
      attrs = params.dig(:admin_user, :permission_grants_attributes)
      if attrs.present?
        if current_admin_user.is_admin?
          attrs.each do |_key, grant_attrs|
            grant_attrs[:granted_by_id] = current_admin_user.id if grant_attrs[:id].blank?
          end
        else
          params[:admin_user].delete(:permission_grants_attributes)
        end
      end
      super
    end
```

**(d)** In the form, after the `pre_profit_share_purchases` `has_many` block (~line 201, still inside `if current_admin_user.is_admin?`), add:

```ruby
        f.has_many :permission_grants, heading: "Permission Grants", allow_destroy: true do |a|
          a.input :permission, as: :select, collection: PermissionGrant::PERMISSIONS, include_blank: false
          a.input :subject_id,
            as: :select,
            collection: ProjectTracker.order(:name).pluck(:name, :id),
            include_blank: "All projects",
            label: "Scope to project",
            hint: "Leave blank for lead-level access to everything (same as someone who has led a project — for leads-in-training). Pick a project to limit them to read-only access to that project's tracker and invoices."
          a.input :notes, hint: "Why this grant exists, e.g. 'Account Lead training, Q3 cohort'."
        end
```

**(e)** In `app/views/admin/admin_users/_show.html.erb`, append at the end of the file:

```erb
<% if current_admin_user.is_admin? && resource.permission_grants.any? %>
  <div class="panel">
    <h3>Permission Grants</h3>
    <div class="panel_contents">
      <table border="0" cellspacing="0" cellpadding="0" class="index_table index">
        <thead>
          <tr>
            <th class="col">Permission</th>
            <th class="col">Scope</th>
            <th class="col">Granted By</th>
            <th class="col">Notes</th>
            <th class="col">Granted At</th>
          </tr>
        </thead>
        <tbody>
          <% resource.permission_grants.each do |grant| %>
            <tr>
              <td class="col"><%= grant.permission.humanize %></td>
              <td class="col"><%= grant.global? ? "All projects" : (grant.subject.respond_to?(:name) ? grant.subject.name : "#{grant.subject_type} ##{grant.subject_id}") %></td>
              <td class="col"><%= grant.granted_by&.email %></td>
              <td class="col"><%= grant.notes %></td>
              <td class="col"><%= grant.created_at.to_date %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
  </div>
<% end %>
```

- [ ] **Step 4: Run the integration tests**

Run: `bin/rails test test/integration/admin_permission_grants_test.rb`
Expected: PASS (all 8)

- [ ] **Step 5: Commit**

```bash
git add app/admin/admin_users.rb app/views/admin/admin_users/_show.html.erb test/integration/admin_permission_grants_test.rb
git commit -m "feat: manage permission grants from the AdminUser admin; guard promote/demote

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Full-suite verification and PR

**Files:**
- No new files. Possibly fix fallout surfaced by the full suite.

**Interfaces:**
- Consumes: everything above.
- Produces: green suite, pushed branch `feat/permission-grants`, open PR to `main`.

- [ ] **Step 1: Run the full test suite**

Run: `bin/rails test`
Expected: 0 failures, 0 errors. If a pre-existing test asserts on `has_led_projects?`-driven authorization, update it to the new `can_act_as_lead?` reality only if the test's intent is authorization; otherwise investigate before touching it.

- [ ] **Step 2: Push and open the PR**

```bash
git checkout -b feat/permission-grants
git push -u origin feat/permission-grants
gh pr create --base main --title "Permission grants: lead-in-training access (global or per-project)" --body "$(cat <<'EOF'
## Summary
- New `permission_grants` table + `PermissionGrant` model: `{admin_user, permission, optional polymorphic subject, granted_by, notes}` — extensible to new permissions/scopes without schema changes
- Global `"lead"` grant ⇒ `AdminUser#can_act_as_lead?` ⇒ identical ActiveAdmin access to someone who has actually led (for team/account leads in training)
- Project-scoped grant ⇒ read-only access to that project's ProjectTracker + the InvoiceTrackers billing it (index pages filtered via new `AdminAuthorization#scope_collection`)
- Admins manage grants from the Everybody (AdminUser) edit form; grants panel on the show page; `granted_by` stamped server-side
- Hardening: `promote_admin_user` / `demote_admin_user` member actions now verify `is_admin?` server-side (previously only the link was hidden — any lead could POST to self-promote)

## Defaulted decisions (see spec)
- Scoped grants are read-only; write-within-scope would be a new permission string later
- Global grants pass the same master gate as real leads (full lead-equivalent visibility)
- Scoped grantees can read InvoicePass pages (needed to navigate to their invoice trackers)
- No `expires_at` — training grants are revoked manually

Spec: `docs/superpowers/specs/2026-08-04-permission-grants-design.md`
Plan: `docs/superpowers/plans/2026-08-04-permission-grants.md`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
