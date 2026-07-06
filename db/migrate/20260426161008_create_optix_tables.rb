class CreateOptixTables < ActiveRecord::Migration[6.1]
  def change
    # Top of the tree. For now we expect exactly one row — but the table exists
    # so we can scope all Optix data by org_id and add a second tenant in the
    # future without restructuring. We deliberately do NOT store credentials
    # here; they live in Rails.credentials and are looked up globally for now.
    create_table :optix_organizations do |t|
      t.string :name, null: false
      # Optix's own internal organization id (from `me.organization_id` etc.).
      # Optional because we may know it AFTER first sync.
      t.string :optix_id
      t.jsonb  :data, default: {}
      t.datetime :synced_at
      t.timestamps
      t.index :optix_id, unique: true, where: "optix_id IS NOT NULL"
    end

    # Optix locations. PK is the Optix-side ID (string) so upserts on sync are
    # natural. All optix_* tables hang off optix_organizations so multi-tenant
    # data stays isolated by FK.
    create_table :optix_locations, id: false do |t|
      t.string :optix_id, primary_key: true
      t.bigint :optix_organization_id, null: false
      t.string :name
      t.string :city
      t.string :region
      t.string :country
      t.string :timezone
      t.boolean :is_visible, default: true,  null: false
      t.boolean :is_hidden,  default: false, null: false
      t.boolean :is_deleted, default: false, null: false
      t.jsonb   :data,       default: {}
      t.datetime :synced_at
      t.timestamps
      t.index :optix_organization_id
    end

    # The "tier" definitions — Hot Desk, Dedicated Desk, Founders, etc.
    create_table :optix_plan_templates, id: false do |t|
      t.string :optix_id, primary_key: true
      t.bigint :optix_organization_id, null: false
      t.string :name,            null: false
      t.float  :price
      t.string :price_frequency
      t.boolean :in_all_locations, default: false, null: false
      t.boolean :onboarding_enabled,     default: true, null: false
      t.boolean :non_onboarding_enabled, default: true, null: false
      t.jsonb   :data,           default: {}
      t.datetime :synced_at
      t.timestamps
      t.index :optix_organization_id
    end

    # Plan templates can be available at multiple specific locations (or "all
    # locations" via the boolean on the parent). This join table holds the
    # explicit per-location associations.
    create_table :optix_plan_template_locations do |t|
      t.string :optix_plan_template_id, null: false
      t.string :optix_location_id,      null: false
      t.timestamps
      t.index [:optix_plan_template_id, :optix_location_id],
        unique: true,
        name: "idx_optix_plan_template_locations_unique"
      t.index :optix_plan_template_id, name: "idx_optix_ptl_on_plan_template"
      t.index :optix_location_id,      name: "idx_optix_ptl_on_location"
    end

    # Members — the people we want a roster of, joinable by email to other
    # Stacks concepts (ForecastPerson, AdminUser) later.
    create_table :optix_users, id: false do |t|
      t.string :optix_id, primary_key: true
      t.bigint :optix_organization_id, null: false
      t.string :email
      t.string :name
      t.string :first_name
      t.string :last_name
      t.boolean :is_active, default: true, null: false
      t.bigint  :created_timestamp
      t.jsonb   :data, default: {}
      t.datetime :synced_at
      t.timestamps
      t.index :optix_organization_id
      # Lookup by email for cross-system matching (e.g. ForecastPerson lookup).
      # Not unique because the same email could in theory show up in multiple
      # OptixOrganizations once we add a second tenant.
      t.index "lower(email)", name: "idx_optix_users_on_lower_email"
    end

    # Each row is one membership instance — an account on a specific plan
    # template with a particular status (ACTIVE / IN_TRIAL / CANCELED / …).
    # We sync ALL statuses so historical timestamps are preserved for
    # month-over-month churn / growth analysis.
    create_table :optix_account_plans, id: false do |t|
      t.string :optix_id, primary_key: true
      t.bigint :optix_organization_id, null: false
      t.string :optix_plan_template_id
      t.string :name
      t.string :status, null: false
      t.float  :price
      t.string :price_frequency
      t.bigint :start_timestamp
      t.bigint :end_timestamp
      t.bigint :canceled_timestamp
      t.bigint :created_timestamp
      # Optix's "account" can be a User or a Team. We capture both refs verbatim
      # so the record stays joinable without us pre-deciding which is canonical.
      t.string :payer_account_optix_id
      # Most-useful linkage for "who is this membership for" — the User who
      # actually consumes the plan's accesses. Nullable because a Team plan
      # may not have a single user; pure Team plans show up with this null.
      t.string :access_usage_user_optix_id
      t.jsonb  :data,    default: {}
      t.datetime :synced_at
      t.timestamps
      t.index :optix_organization_id
      t.index :optix_plan_template_id
      t.index :access_usage_user_optix_id
      t.index :status
      t.index :start_timestamp
      t.index :end_timestamp
    end
  end
end
