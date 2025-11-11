# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema.define(version: 2025_11_11_224743) do

  # These are extensions that must be enabled in order to support this database
  enable_extension "btree_gist"
  enable_extension "pg_stat_statements"
  enable_extension "plpgsql"

  create_table "account_lead_periods", force: :cascade do |t|
    t.bigint "project_tracker_id", null: false
    t.bigint "admin_user_id", null: false
    t.date "started_at"
    t.date "ended_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_account_lead_periods_on_admin_user_id"
    t.index ["project_tracker_id"], name: "index_account_lead_periods_on_project_tracker_id"
  end

  create_table "active_admin_comments", force: :cascade do |t|
    t.string "namespace"
    t.text "body"
    t.string "resource_type"
    t.bigint "resource_id"
    t.string "author_type"
    t.bigint "author_id"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["author_type", "author_id"], name: "index_active_admin_comments_on_author_type_and_author_id"
    t.index ["namespace"], name: "index_active_admin_comments_on_namespace"
    t.index ["resource_type", "resource_id"], name: "index_active_admin_comments_on_resource_type_and_resource_id"
  end

  create_table "adhoc_invoice_trackers", force: :cascade do |t|
    t.string "qbo_invoice_id", null: false
    t.bigint "project_tracker_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["project_tracker_id"], name: "index_adhoc_invoice_trackers_on_project_tracker_id"
    t.index ["qbo_invoice_id", "project_tracker_id"], name: "index_adhoc_invoice_trackers_on_qbo_invoice_and_project_tracker", unique: true
  end

  create_table "admin_user_communities", force: :cascade do |t|
    t.bigint "community_id", null: false
    t.bigint "admin_user_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_admin_user_communities_on_admin_user_id"
    t.index ["community_id"], name: "index_admin_user_communities_on_community_id"
  end

  create_table "admin_user_cultural_backgrounds", force: :cascade do |t|
    t.bigint "cultural_background_id", null: false
    t.bigint "admin_user_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_admin_user_cultural_backgrounds_on_admin_user_id"
    t.index ["cultural_background_id"], name: "index_admin_user_cultural_backgrounds_on_cultural_background_id"
  end

  create_table "admin_user_gender_identities", force: :cascade do |t|
    t.bigint "gender_identity_id", null: false
    t.bigint "admin_user_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_admin_user_gender_identities_on_admin_user_id"
    t.index ["gender_identity_id"], name: "index_admin_user_gender_identities_on_gender_identity_id"
  end

  create_table "admin_user_interests", force: :cascade do |t|
    t.bigint "interest_id", null: false
    t.bigint "admin_user_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_admin_user_interests_on_admin_user_id"
    t.index ["interest_id"], name: "index_admin_user_interests_on_interest_id"
  end

  create_table "admin_user_racial_backgrounds", force: :cascade do |t|
    t.bigint "racial_background_id", null: false
    t.bigint "admin_user_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_admin_user_racial_backgrounds_on_admin_user_id"
    t.index ["racial_background_id"], name: "index_admin_user_racial_backgrounds_on_racial_background_id"
  end

  create_table "admin_user_salary_windows", force: :cascade do |t|
    t.bigint "admin_user_id", null: false
    t.decimal "salary", null: false
    t.date "start_date", null: false
    t.date "end_date"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_admin_user_salary_windows_on_admin_user_id"
  end

  create_table "admin_users", force: :cascade do |t|
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.string "provider"
    t.string "uid"
    t.string "roles", default: [], array: true
    t.boolean "show_skill_tree_data", default: true
    t.integer "old_skill_tree_level"
    t.text "profit_share_notes"
    t.jsonb "info", default: {}
    t.boolean "ignore", default: false
    t.integer "github_user_id"
    t.index ["email"], name: "index_admin_users_on_email", unique: true
    t.index ["github_user_id"], name: "index_admin_users_on_github_user_id", unique: true
    t.index ["reset_password_token"], name: "index_admin_users_on_reset_password_token", unique: true
  end

  create_table "associates_award_agreements", force: :cascade do |t|
    t.bigint "admin_user_id", null: false
    t.date "started_at", null: false
    t.integer "initial_unit_grant", null: false
    t.integer "vesting_unit_increments", null: false
    t.integer "vesting_periods", null: false
    t.integer "vesting_period_type", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_associates_award_agreements_on_admin_user_id"
  end

  create_table "collective_role_holder_periods", force: :cascade do |t|
    t.bigint "collective_role_id", null: false
    t.bigint "admin_user_id", null: false
    t.date "started_at"
    t.date "ended_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_collective_role_holder_periods_on_admin_user_id"
    t.index ["collective_role_id"], name: "index_collective_role_holder_periods_on_collective_role_id"
  end

  create_table "collective_roles", force: :cascade do |t|
    t.string "name", null: false
    t.string "notion_link", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.decimal "leadership_psu_pool_weighting", default: "0.0"
  end

  create_table "communities", force: :cascade do |t|
    t.string "name"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "contacts", force: :cascade do |t|
    t.string "email", null: false
    t.string "sources", default: [], array: true
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.string "apollo_id"
    t.jsonb "apollo_data", default: {}
    t.index ["apollo_id"], name: "index_contacts_on_apollo_id", unique: true
    t.index ["email"], name: "index_contacts_on_email", unique: true
  end

  create_table "contributor_payouts", force: :cascade do |t|
    t.bigint "invoice_tracker_id", null: false
    t.bigint "forecast_person_id", null: false
    t.bigint "created_by_id", null: false
    t.decimal "amount", default: "0.0", null: false
    t.jsonb "blueprint", default: {}, null: false
    t.text "description"
    t.datetime "accepted_at"
    t.datetime "deleted_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["created_by_id"], name: "index_contributor_payouts_on_created_by_id"
    t.index ["deleted_at"], name: "index_contributor_payouts_on_deleted_at"
    t.index ["forecast_person_id"], name: "index_contributor_payouts_on_forecast_person_id"
    t.index ["invoice_tracker_id"], name: "index_contributor_payouts_on_invoice_tracker_id"
  end

  create_table "creative_lead_periods", force: :cascade do |t|
    t.bigint "project_tracker_id", null: false
    t.bigint "admin_user_id", null: false
    t.bigint "studio_id", null: false
    t.date "started_at"
    t.date "ended_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_creative_lead_periods_on_admin_user_id"
    t.index ["project_tracker_id"], name: "index_creative_lead_periods_on_project_tracker_id"
    t.index ["studio_id"], name: "index_creative_lead_periods_on_studio_id"
  end

  create_table "cultural_backgrounds", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.boolean "opt_out"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "deel_contracts", force: :cascade do |t|
    t.string "deel_id", null: false
    t.jsonb "data", null: false
    t.string "deel_person_id", null: false
    t.index ["deel_id"], name: "index_deel_contracts_on_deel_id", unique: true
  end

  create_table "deel_off_cycle_payments", force: :cascade do |t|
    t.string "deel_id"
    t.string "deel_contract_id"
    t.jsonb "data"
    t.datetime "created_at", null: false
    t.datetime "submitted_at"
    t.index ["deel_contract_id"], name: "index_deel_off_cycle_payments_on_deel_contract_id"
    t.index ["deel_id"], name: "index_deel_off_cycle_payments_on_deel_id", unique: true
  end

  create_table "deel_people", force: :cascade do |t|
    t.string "deel_id", null: false
    t.jsonb "data", null: false
    t.index ["deel_id"], name: "index_deel_people_on_deel_id", unique: true
  end

  create_table "dei_rollups", force: :cascade do |t|
    t.jsonb "data"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "enterprises", force: :cascade do |t|
    t.string "name", null: false
    t.jsonb "snapshot", default: {}
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "finalizations", force: :cascade do |t|
    t.bigint "review_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.datetime "deleted_at"
    t.index ["deleted_at"], name: "index_finalizations_on_deleted_at"
    t.index ["review_id"], name: "index_finalizations_on_review_id"
  end

  create_table "forecast_assignment_daily_financial_snapshots", force: :cascade do |t|
    t.bigint "forecast_assignment_id", null: false
    t.bigint "forecast_person_id", null: false
    t.bigint "forecast_project_id", null: false
    t.date "effective_date", null: false
    t.bigint "studio_id", null: false
    t.decimal "hourly_cost", null: false
    t.decimal "hours", null: false
    t.boolean "needs_review", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["forecast_assignment_id"], name: "idx_snapshots_on_forecast_assignment_id"
    t.index ["forecast_person_id"], name: "idx_snapshots_on_forecast_person_id"
    t.index ["forecast_project_id"], name: "idx_snapshots_on_forecast_project_id"
    t.index ["needs_review"], name: "idx_snapshots_on_needs_review"
  end

  create_table "forecast_assignments", force: :cascade do |t|
    t.integer "forecast_id"
    t.datetime "updated_at"
    t.integer "updated_by_id"
    t.integer "allocation"
    t.date "start_date"
    t.date "end_date"
    t.text "notes"
    t.integer "project_id"
    t.integer "person_id"
    t.integer "placeholder_id"
    t.integer "repeated_assignment_set_id"
    t.boolean "active_on_days_off"
    t.jsonb "data"
    t.index ["allocation"], name: "index_forecast_assignments_on_allocation"
    t.index ["end_date"], name: "index_forecast_assignments_on_end_date"
    t.index ["forecast_id"], name: "index_forecast_assignments_on_forecast_id", unique: true
    t.index ["person_id", "project_id", "start_date", "end_date"], name: "idx_assignments_on_person_project_and_daterange", using: :gist
    t.index ["person_id", "start_date", "end_date"], name: "idx_assignments_on_person_and_daterange", using: :gist
    t.index ["person_id"], name: "index_forecast_assignments_on_person_id"
    t.index ["project_id", "start_date", "end_date"], name: "idx_assignments_on_project_and_daterange", using: :gist
    t.index ["project_id", "start_date"], name: "index_forecast_assignments_on_project_id_and_start_date"
    t.index ["project_id"], name: "index_forecast_assignments_on_project_id"
    t.index ["start_date", "end_date"], name: "idx_assignments_on_daterange", using: :gist
    t.index ["start_date"], name: "index_forecast_assignments_on_start_date"
  end

  create_table "forecast_clients", force: :cascade do |t|
    t.integer "forecast_id"
    t.string "name"
    t.integer "harvest_id"
    t.boolean "archived"
    t.datetime "updated_at"
    t.integer "updated_by_id"
    t.jsonb "data"
    t.index ["forecast_id"], name: "index_forecast_clients_on_forecast_id", unique: true
  end

  create_table "forecast_people", force: :cascade do |t|
    t.integer "forecast_id"
    t.string "first_name"
    t.string "last_name"
    t.string "email"
    t.text "roles", default: [], array: true
    t.boolean "archived"
    t.datetime "updated_at"
    t.integer "updated_by_id"
    t.jsonb "data"
    t.index ["forecast_id"], name: "index_forecast_people_on_forecast_id", unique: true
  end

  create_table "forecast_person_utilization_reports", force: :cascade do |t|
    t.integer "forecast_person_id", null: false
    t.date "starts_at", null: false
    t.date "ends_at", null: false
    t.decimal "expected_hours_sold", precision: 10, scale: 2, null: false
    t.decimal "expected_hours_unsold", precision: 10, scale: 2, null: false
    t.decimal "actual_hours_sold", precision: 10, scale: 2, null: false
    t.decimal "actual_hours_internal", precision: 10, scale: 2, null: false
    t.decimal "actual_hours_time_off", precision: 10, scale: 2, null: false
    t.jsonb "actual_hours_sold_by_rate", null: false
    t.decimal "utilization_rate", precision: 10, scale: 2, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["forecast_person_id", "starts_at", "ends_at"], name: "idx_forecast_person_utilization", unique: true
    t.index ["forecast_person_id"], name: "index_forecast_person_utilization_reports_on_forecast_person_id"
  end

  create_table "forecast_projects", force: :cascade do |t|
    t.integer "forecast_id"
    t.jsonb "data"
    t.string "name"
    t.string "code"
    t.text "notes"
    t.date "start_date"
    t.date "end_date"
    t.integer "harvest_id"
    t.boolean "archived"
    t.integer "client_id"
    t.text "tags", default: [], array: true
    t.datetime "updated_at"
    t.integer "updated_by_id"
    t.index ["client_id"], name: "index_forecast_projects_on_client_id"
    t.index ["forecast_id"], name: "index_forecast_projects_on_forecast_id", unique: true
  end

  create_table "full_time_periods", force: :cascade do |t|
    t.bigint "admin_user_id", null: false
    t.date "started_at"
    t.date "ended_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.decimal "expected_utilization", default: "0.8"
    t.integer "contributor_type", default: 0
    t.boolean "considered_temporary", default: false
    t.index ["admin_user_id"], name: "index_full_time_periods_on_admin_user_id"
  end

  create_table "gender_identities", force: :cascade do |t|
    t.string "name"
    t.boolean "opt_out"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "gifted_profit_shares", force: :cascade do |t|
    t.bigint "admin_user_id", null: false
    t.decimal "amount"
    t.string "reason"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_gifted_profit_shares_on_admin_user_id"
  end

  create_table "github_issues", force: :cascade do |t|
    t.bigint "github_id", null: false
    t.string "github_node_id", null: false
    t.string "title", null: false
    t.jsonb "data", null: false
    t.bigint "github_repo_id", null: false
    t.bigint "github_user_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["github_id"], name: "index_github_issues_on_github_id", unique: true
    t.index ["github_node_id"], name: "index_github_issues_on_github_node_id", unique: true
  end

  create_table "github_pull_requests", force: :cascade do |t|
    t.string "title", default: "", null: false
    t.bigint "time_to_merge"
    t.bigint "github_id", null: false
    t.bigint "github_repo_id", null: false
    t.bigint "github_user_id", null: false
    t.jsonb "data", null: false
    t.datetime "merged_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["github_id"], name: "index_github_pull_requests_on_github_id", unique: true
    t.index ["github_repo_id"], name: "index_github_pull_requests_on_github_repo_id"
    t.index ["github_user_id"], name: "index_github_pull_requests_on_github_user_id"
    t.index ["merged_at"], name: "index_github_pull_requests_on_merged_at"
  end

  create_table "github_repos", force: :cascade do |t|
    t.bigint "github_id", null: false
    t.string "name", null: false
    t.jsonb "data", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["github_id"], name: "index_github_repos_on_github_id", unique: true
  end

  create_table "github_users", force: :cascade do |t|
    t.bigint "github_id", null: false
    t.string "login", null: false
    t.jsonb "data", null: false
    t.index ["github_id"], name: "index_github_users_on_github_id", unique: true
  end

  create_table "interests", force: :cascade do |t|
    t.string "name"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "invoice_passes", force: :cascade do |t|
    t.date "start_of_month"
    t.datetime "completed_at"
    t.jsonb "data"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["start_of_month"], name: "index_invoice_passes_on_start_of_month", unique: true
  end

  create_table "invoice_trackers", force: :cascade do |t|
    t.bigint "forecast_client_id", null: false
    t.bigint "invoice_pass_id", null: false
    t.string "qbo_invoice_id"
    t.jsonb "blueprint"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.bigint "admin_user_id"
    t.text "notes"
    t.date "allow_early_contributor_payouts_on"
    t.decimal "company_treasury_split", default: "0.3"
    t.index ["admin_user_id"], name: "index_invoice_trackers_on_admin_user_id"
    t.index ["forecast_client_id", "invoice_pass_id"], name: "idx_invoice_trackers_on_forecast_client_id_and_invoice_pass_id", unique: true
    t.index ["forecast_client_id"], name: "index_invoice_trackers_on_forecast_client_id"
    t.index ["invoice_pass_id"], name: "index_invoice_trackers_on_invoice_pass_id"
    t.check_constraint "(company_treasury_split >= (0)::numeric) AND (company_treasury_split <= (1)::numeric)", name: "check_company_treasury_split_range"
  end

  create_table "mailing_list_subscribers", force: :cascade do |t|
    t.bigint "mailing_list_id", null: false
    t.string "email", null: false
    t.jsonb "info", default: "{}", null: false
    t.index ["mailing_list_id", "email"], name: "index_mailing_list_subscribers_on_mailing_list_id_and_email", unique: true
    t.index ["mailing_list_id"], name: "index_mailing_list_subscribers_on_mailing_list_id"
  end

  create_table "mailing_lists", force: :cascade do |t|
    t.string "name", null: false
    t.bigint "studio_id", null: false
    t.jsonb "snapshot", default: {}, null: false
    t.integer "provider", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["studio_id"], name: "index_mailing_lists_on_studio_id"
  end

  create_table "misc_payments", force: :cascade do |t|
    t.integer "forecast_person_id", null: false
    t.decimal "amount", precision: 10, scale: 2, null: false
    t.text "remittance"
    t.datetime "deleted_at"
    t.date "paid_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["deleted_at"], name: "index_misc_payments_on_deleted_at"
    t.index ["forecast_person_id"], name: "index_misc_payments_on_forecast_person_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.string "recipient_type", null: false
    t.bigint "recipient_id", null: false
    t.string "type", null: false
    t.jsonb "params"
    t.datetime "read_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["read_at"], name: "index_notifications_on_read_at"
    t.index ["recipient_type", "recipient_id"], name: "index_notifications_on_recipient_type_and_recipient_id"
  end

  create_table "notion_pages", force: :cascade do |t|
    t.string "notion_id", null: false
    t.string "notion_parent_type"
    t.string "notion_parent_id"
    t.jsonb "data", default: {}, null: false
    t.string "page_title", default: "", null: false
    t.datetime "deleted_at"
    t.index ["deleted_at"], name: "index_notion_pages_on_deleted_at"
    t.index ["notion_id"], name: "index_notion_pages_on_notion_id", unique: true
  end

  create_table "okr_period_studios", force: :cascade do |t|
    t.bigint "studio_id", null: false
    t.bigint "okr_period_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["okr_period_id"], name: "index_okr_period_studios_on_okr_period_id"
    t.index ["studio_id"], name: "index_okr_period_studios_on_studio_id"
  end

  create_table "okr_periods", force: :cascade do |t|
    t.bigint "okr_id", null: false
    t.date "starts_at"
    t.date "ends_at"
    t.decimal "target", null: false
    t.decimal "tolerance", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["okr_id"], name: "index_okr_periods_on_okr_id"
  end

  create_table "okrs", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.integer "operator", default: 0
    t.integer "datapoint", default: 0
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "peer_reviews", force: :cascade do |t|
    t.bigint "admin_user_id", null: false
    t.bigint "review_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.datetime "deleted_at"
    t.index ["admin_user_id"], name: "index_peer_reviews_on_admin_user_id"
    t.index ["deleted_at"], name: "index_peer_reviews_on_deleted_at"
    t.index ["review_id"], name: "index_peer_reviews_on_review_id"
  end

  create_table "pre_profit_share_purchases", force: :cascade do |t|
    t.bigint "admin_user_id", null: false
    t.decimal "amount"
    t.string "note"
    t.date "purchased_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_pre_profit_share_purchases_on_admin_user_id"
  end

  create_table "profit_share_passes", force: :cascade do |t|
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.decimal "payroll_buffer_months", default: "1.5"
    t.decimal "efficiency_cap", default: "1.6"
    t.jsonb "snapshot"
    t.decimal "internals_budget_multiplier", default: "0.5"
    t.text "description"
    t.integer "leadership_psu_pool_cap", default: 0
    t.decimal "leadership_psu_pool_project_role_holders_percentage", default: "0.0"
  end

  create_table "profit_share_payments", force: :cascade do |t|
    t.bigint "admin_user_id", null: false
    t.bigint "profit_share_pass_id", null: false
    t.float "tenured_psu_earnt", default: 0.0
    t.float "project_leadership_psu_earnt", default: 0.0
    t.float "collective_leadership_psu_earnt", default: 0.0
    t.float "pre_spent_profit_share", default: 0.0
    t.float "total_payout", default: 0.0
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_profit_share_payments_on_admin_user_id"
    t.index ["profit_share_pass_id"], name: "index_profit_share_payments_on_profit_share_pass_id"
  end

  create_table "project_capsules", force: :cascade do |t|
    t.bigint "project_tracker_id", null: false
    t.text "postpartum_notes"
    t.integer "client_feedback_survey_status"
    t.string "client_feedback_survey_url"
    t.integer "internal_marketing_status"
    t.integer "capsule_status"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.integer "client_satisfaction_status"
    t.text "client_satisfaction_detail"
    t.integer "project_satisfaction_survey_status"
    t.index ["project_tracker_id"], name: "index_project_capsules_on_project_tracker_id"
  end

  create_table "project_lead_periods", force: :cascade do |t|
    t.bigint "project_tracker_id", null: false
    t.bigint "admin_user_id", null: false
    t.bigint "studio_id", null: false
    t.date "started_at"
    t.date "ended_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_project_lead_periods_on_admin_user_id"
    t.index ["project_tracker_id"], name: "index_project_lead_periods_on_project_tracker_id"
    t.index ["studio_id"], name: "index_project_lead_periods_on_studio_id"
  end

  create_table "project_safety_representative_periods", force: :cascade do |t|
    t.bigint "project_tracker_id", null: false
    t.bigint "admin_user_id", null: false
    t.bigint "studio_id", null: false
    t.date "started_at"
    t.date "ended_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "idx_project_safety_rep_periods_on_admin_user_id"
    t.index ["project_tracker_id"], name: "idx_project_safety_rep_periods_on_project_tracker_id"
    t.index ["studio_id"], name: "idx_project_safety_rep_periods_on_studio_id"
  end

  create_table "project_satisfaction_survey_free_text_question_responses", force: :cascade do |t|
    t.bigint "project_satisfaction_survey_response_id", null: false
    t.bigint "project_satisfaction_survey_free_text_question_id", null: false
    t.string "response"
    t.index ["project_satisfaction_survey_free_text_question_id"], name: "idx_pssftqr_on_pssftq_id"
    t.index ["project_satisfaction_survey_response_id"], name: "idx_pssftqr_on_pssr_id"
  end

  create_table "project_satisfaction_survey_free_text_questions", force: :cascade do |t|
    t.bigint "project_satisfaction_survey_id", null: false
    t.string "prompt", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["project_satisfaction_survey_id"], name: "idx_pssftq_on_pss_id"
  end

  create_table "project_satisfaction_survey_question_responses", force: :cascade do |t|
    t.bigint "project_satisfaction_survey_response_id", null: false
    t.bigint "project_satisfaction_survey_question_id", null: false
    t.integer "sentiment", default: 0
    t.string "context"
    t.index ["project_satisfaction_survey_question_id"], name: "idx_pssqr_on_pssq_id"
    t.index ["project_satisfaction_survey_response_id"], name: "idx_pssqr_on_pssr_id"
  end

  create_table "project_satisfaction_survey_questions", comment: "Table for project satisfaction survey questions", force: :cascade do |t|
    t.bigint "project_satisfaction_survey_id", null: false
    t.string "prompt", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["project_satisfaction_survey_id"], name: "idx_pssq_on_pss_id"
  end

  create_table "project_satisfaction_survey_responders", force: :cascade do |t|
    t.bigint "project_satisfaction_survey_id", null: false
    t.bigint "admin_user_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_project_satisfaction_survey_responders_on_admin_user_id"
    t.index ["project_satisfaction_survey_id", "admin_user_id"], name: "idx_ps_survey_responders_on_survey_id_and_admin_user_id", unique: true
    t.index ["project_satisfaction_survey_id"], name: "idx_pssr_on_ps_survey_id"
  end

  create_table "project_satisfaction_survey_responses", force: :cascade do |t|
    t.bigint "project_satisfaction_survey_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["project_satisfaction_survey_id"], name: "idx_pssr_on_pss_id"
  end

  create_table "project_satisfaction_surveys", force: :cascade do |t|
    t.bigint "project_capsule_id", null: false
    t.string "title", null: false
    t.text "description", null: false
    t.datetime "closed_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["project_capsule_id"], name: "index_project_satisfaction_surveys_on_project_capsule_id"
  end

  create_table "project_tracker_forecast_projects", force: :cascade do |t|
    t.bigint "project_tracker_id", null: false
    t.bigint "forecast_project_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["forecast_project_id"], name: "index_project_tracker_forecast_projects_on_forecast_project_id"
    t.index ["project_tracker_id"], name: "index_project_tracker_forecast_projects_on_project_tracker_id"
  end

  create_table "project_tracker_forecast_to_runn_sync_tasks", force: :cascade do |t|
    t.bigint "project_tracker_id"
    t.datetime "settled_at"
    t.bigint "notification_id"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["notification_id"], name: "idx_pt_forecast_to_runn_sync_tasks_on_notification_id"
    t.index ["project_tracker_id"], name: "idx_pt_forecast_to_runn_sync_tasks_on_pt_id"
  end

  create_table "project_tracker_links", force: :cascade do |t|
    t.string "name", null: false
    t.string "url", null: false
    t.integer "link_type", default: 0
    t.bigint "project_tracker_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["project_tracker_id"], name: "index_project_tracker_links_on_project_tracker_id"
  end

  create_table "project_tracker_zenhub_workspaces", force: :cascade do |t|
    t.bigint "project_tracker_id", null: false
    t.string "zenhub_workspace_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["project_tracker_id", "zenhub_workspace_id"], name: "idx_project_tracker_zenhub_workspace", unique: true
    t.index ["project_tracker_id"], name: "index_project_tracker_zenhub_workspaces_on_project_tracker_id"
  end

  create_table "project_trackers", force: :cascade do |t|
    t.string "name"
    t.decimal "budget_low_end"
    t.decimal "budget_high_end"
    t.text "notes"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.datetime "work_completed_at"
    t.jsonb "snapshot", default: {}
    t.decimal "target_free_hours_percent", default: "0.0"
    t.decimal "target_profit_margin", default: "0.0"
    t.bigint "runn_project_id"
    t.decimal "company_treasury_split", default: "0.3"
    t.index ["runn_project_id"], name: "index_project_trackers_on_runn_project_id", unique: true
    t.check_constraint "(company_treasury_split >= (0)::numeric) AND (company_treasury_split <= (1)::numeric)", name: "check_company_treasury_split_range"
  end

  create_table "qbo_accounts", force: :cascade do |t|
    t.string "client_id", null: false
    t.string "client_secret", null: false
    t.string "realm_id", null: false
    t.bigint "enterprise_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["enterprise_id"], name: "index_qbo_accounts_on_enterprise_id"
  end

  create_table "qbo_invoices", force: :cascade do |t|
    t.string "qbo_id", null: false
    t.jsonb "data"
    t.index ["qbo_id"], name: "index_qbo_invoices_on_qbo_id", unique: true, where: "(qbo_id IS NOT NULL)"
  end

  create_table "qbo_profit_and_loss_reports", force: :cascade do |t|
    t.date "starts_at", null: false
    t.date "ends_at", null: false
    t.jsonb "data", default: "{}"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.bigint "qbo_account_id"
    t.index ["qbo_account_id"], name: "index_qbo_profit_and_loss_reports_on_qbo_account_id"
  end

  create_table "qbo_tokens", force: :cascade do |t|
    t.string "token", null: false
    t.string "refresh_token", null: false
    t.bigint "qbo_account_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["qbo_account_id"], name: "index_qbo_tokens_on_qbo_account_id"
  end

  create_table "quickbooks_tokens", force: :cascade do |t|
    t.string "token"
    t.string "refresh_token"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "racial_backgrounds", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.boolean "opt_out"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "review_trees", force: :cascade do |t|
    t.bigint "review_id", null: false
    t.bigint "tree_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.datetime "deleted_at"
    t.index ["deleted_at"], name: "index_review_trees_on_deleted_at"
    t.index ["review_id"], name: "index_review_trees_on_review_id"
    t.index ["tree_id"], name: "index_review_trees_on_tree_id"
  end

  create_table "reviews", force: :cascade do |t|
    t.bigint "admin_user_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.datetime "archived_at"
    t.datetime "deleted_at"
    t.index ["admin_user_id"], name: "index_reviews_on_admin_user_id"
    t.index ["deleted_at"], name: "index_reviews_on_deleted_at"
  end

  create_table "runn_projects", force: :cascade do |t|
    t.bigint "runn_id", null: false
    t.string "name"
    t.boolean "is_template"
    t.boolean "is_archived"
    t.boolean "is_confirmed"
    t.string "pricing_model"
    t.string "rate_type"
    t.integer "budget"
    t.integer "expenses_budget"
    t.datetime "created_at"
    t.datetime "updated_at"
    t.jsonb "data"
    t.index ["runn_id"], name: "index_runn_projects_on_runn_id", unique: true
  end

  create_table "score_trees", force: :cascade do |t|
    t.bigint "tree_id", null: false
    t.bigint "workspace_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.datetime "deleted_at"
    t.index ["deleted_at"], name: "index_score_trees_on_deleted_at"
    t.index ["tree_id"], name: "index_score_trees_on_tree_id"
    t.index ["workspace_id"], name: "index_score_trees_on_workspace_id"
  end

  create_table "scores", force: :cascade do |t|
    t.bigint "trait_id", null: false
    t.bigint "score_tree_id", null: false
    t.integer "band"
    t.integer "consistency"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.datetime "deleted_at"
    t.index ["deleted_at"], name: "index_scores_on_deleted_at"
    t.index ["score_tree_id"], name: "index_scores_on_score_tree_id"
    t.index ["trait_id"], name: "index_scores_on_trait_id"
  end

  create_table "studio_coordinator_periods", force: :cascade do |t|
    t.bigint "studio_id", null: false
    t.bigint "admin_user_id", null: false
    t.date "started_at", null: false
    t.date "ended_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_studio_coordinator_periods_on_admin_user_id"
    t.index ["studio_id"], name: "index_studio_coordinator_periods_on_studio_id"
  end

  create_table "studio_memberships", force: :cascade do |t|
    t.bigint "admin_user_id", null: false
    t.bigint "studio_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.date "started_at", null: false
    t.date "ended_at"
    t.index ["admin_user_id", "studio_id"], name: "index_studio_memberships_on_admin_user_id_and_studio_id", unique: true
    t.index ["admin_user_id"], name: "index_studio_memberships_on_admin_user_id"
    t.index ["studio_id"], name: "index_studio_memberships_on_studio_id"
  end

  create_table "studios", force: :cascade do |t|
    t.string "accounting_prefix"
    t.string "name"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.string "mini_name"
    t.jsonb "snapshot", default: {}
    t.integer "studio_type", default: 0
  end

  create_table "survey_free_text_question_responses", force: :cascade do |t|
    t.bigint "survey_response_id", null: false
    t.bigint "survey_free_text_question_id", null: false
    t.string "response"
    t.index ["survey_free_text_question_id"], name: "idx_sftqr_on_sftq_id"
    t.index ["survey_response_id"], name: "index_survey_free_text_question_responses_on_survey_response_id"
  end

  create_table "survey_free_text_questions", force: :cascade do |t|
    t.bigint "survey_id", null: false
    t.string "prompt", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["survey_id"], name: "index_survey_free_text_questions_on_survey_id"
  end

  create_table "survey_question_responses", force: :cascade do |t|
    t.bigint "survey_response_id", null: false
    t.bigint "survey_question_id", null: false
    t.integer "sentiment", default: 0
    t.string "context"
    t.index ["survey_question_id"], name: "index_survey_question_responses_on_survey_question_id"
    t.index ["survey_response_id"], name: "index_survey_question_responses_on_survey_response_id"
  end

  create_table "survey_questions", force: :cascade do |t|
    t.bigint "survey_id", null: false
    t.string "prompt", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["survey_id"], name: "index_survey_questions_on_survey_id"
  end

  create_table "survey_responders", force: :cascade do |t|
    t.bigint "survey_id", null: false
    t.bigint "admin_user_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_survey_responders_on_admin_user_id"
    t.index ["survey_id", "admin_user_id"], name: "idx_survey_responders_on_survey_id_and_admin_user_id", unique: true
    t.index ["survey_id"], name: "index_survey_responders_on_survey_id"
  end

  create_table "survey_responses", force: :cascade do |t|
    t.bigint "survey_id", null: false
    t.index ["survey_id"], name: "index_survey_responses_on_survey_id"
  end

  create_table "survey_studios", force: :cascade do |t|
    t.bigint "survey_id", null: false
    t.bigint "studio_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["studio_id"], name: "index_survey_studios_on_studio_id"
    t.index ["survey_id"], name: "index_survey_studios_on_survey_id"
  end

  create_table "surveys", force: :cascade do |t|
    t.string "title", null: false
    t.text "description", null: false
    t.date "opens_at"
    t.datetime "closed_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "system_tasks", force: :cascade do |t|
    t.string "name", null: false
    t.datetime "settled_at"
    t.bigint "notification_id"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["notification_id"], name: "index_system_tasks_on_notification_id"
  end

  create_table "systems", force: :cascade do |t|
    t.jsonb "settings"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "team_lead_periods", force: :cascade do |t|
    t.bigint "project_tracker_id", null: false
    t.bigint "admin_user_id", null: false
    t.date "started_at"
    t.date "ended_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_team_lead_periods_on_admin_user_id"
    t.index ["project_tracker_id"], name: "index_team_lead_periods_on_project_tracker_id"
  end

  create_table "technical_lead_periods", force: :cascade do |t|
    t.bigint "project_tracker_id", null: false
    t.bigint "admin_user_id", null: false
    t.bigint "studio_id", null: false
    t.date "started_at"
    t.date "ended_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_technical_lead_periods_on_admin_user_id"
    t.index ["project_tracker_id"], name: "index_technical_lead_periods_on_project_tracker_id"
    t.index ["studio_id"], name: "index_technical_lead_periods_on_studio_id"
  end

  create_table "traits", force: :cascade do |t|
    t.bigint "tree_id", null: false
    t.string "name"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["tree_id"], name: "index_traits_on_tree_id"
  end

  create_table "trees", force: :cascade do |t|
    t.string "name"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "trueups", force: :cascade do |t|
    t.bigint "invoice_pass_id", null: false
    t.bigint "forecast_person_id", null: false
    t.decimal "amount", default: "0.0", null: false
    t.text "description"
    t.datetime "deleted_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["forecast_person_id"], name: "index_trueups_on_forecast_person_id"
    t.index ["invoice_pass_id"], name: "index_trueups_on_invoice_pass_id"
  end

  create_table "versions", force: :cascade do |t|
    t.string "item_type", null: false
    t.bigint "item_id", null: false
    t.string "event", null: false
    t.string "whodunnit"
    t.text "object"
    t.datetime "created_at"
    t.text "object_changes"
    t.index ["item_type", "item_id"], name: "index_versions_on_item_type_and_item_id"
  end

  create_table "workspaces", force: :cascade do |t|
    t.string "reviewable_type", null: false
    t.bigint "reviewable_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.integer "status", default: 0
    t.text "notes"
    t.datetime "deleted_at"
    t.index ["deleted_at"], name: "index_workspaces_on_deleted_at"
    t.index ["reviewable_type", "reviewable_id"], name: "index_workspaces_on_reviewable_type_and_reviewable_id"
  end

  create_table "zenhub_issue_assignees", force: :cascade do |t|
    t.string "zenhub_issue_id", null: false
    t.integer "github_user_id", null: false
    t.index ["zenhub_issue_id", "github_user_id"], name: "idx_zenhub_issue_assignees", unique: true
  end

  create_table "zenhub_issue_connected_pull_requests", force: :cascade do |t|
    t.string "zenhub_issue_id", null: false
    t.string "zenhub_pull_request_issue_id", null: false
    t.index ["zenhub_issue_id", "zenhub_pull_request_issue_id"], name: "idx_zenhub_issue_connected_pull_requests", unique: true
  end

  create_table "zenhub_issues", force: :cascade do |t|
    t.string "zenhub_id", null: false
    t.integer "github_repo_id", null: false
    t.integer "github_user_id"
    t.integer "issue_type", default: 0, null: false
    t.integer "issue_state", default: 0, null: false
    t.integer "estimate"
    t.integer "number"
    t.integer "github_issue_id"
    t.string "github_issue_node_id"
    t.string "title"
    t.boolean "is_pull_request", default: false, null: false
    t.datetime "closed_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["closed_at"], name: "index_zenhub_issues_on_closed_at"
    t.index ["zenhub_id"], name: "index_zenhub_issues_on_zenhub_id", unique: true
  end

  create_table "zenhub_workspace_github_repository_connections", force: :cascade do |t|
    t.string "zenhub_id"
    t.string "zenhub_workspace_id"
    t.integer "github_repo_id"
    t.index ["zenhub_id"], name: "idx_zenhub_workspace_github_repo_connections_zenhub_id", unique: true
    t.index ["zenhub_workspace_id", "github_repo_id"], name: "idx_zenhub_workspace_github_repo_connections", unique: true
  end

  create_table "zenhub_workspace_issue_connections", force: :cascade do |t|
    t.string "zenhub_workspace_id", null: false
    t.string "zenhub_issue_id", null: false
    t.index ["zenhub_workspace_id", "zenhub_issue_id"], name: "idx_zenhub_workspace_issue_connections_on_workspace_and_issue", unique: true
  end

  create_table "zenhub_workspaces", force: :cascade do |t|
    t.string "zenhub_id"
    t.string "name"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["zenhub_id"], name: "index_zenhub_workspaces_on_zenhub_id", unique: true
  end

  add_foreign_key "account_lead_periods", "admin_users"
  add_foreign_key "account_lead_periods", "project_trackers"
  add_foreign_key "adhoc_invoice_trackers", "project_trackers"
  add_foreign_key "admin_user_communities", "admin_users"
  add_foreign_key "admin_user_communities", "communities"
  add_foreign_key "admin_user_cultural_backgrounds", "admin_users"
  add_foreign_key "admin_user_cultural_backgrounds", "cultural_backgrounds"
  add_foreign_key "admin_user_gender_identities", "admin_users"
  add_foreign_key "admin_user_gender_identities", "gender_identities"
  add_foreign_key "admin_user_interests", "admin_users"
  add_foreign_key "admin_user_interests", "interests"
  add_foreign_key "admin_user_racial_backgrounds", "admin_users"
  add_foreign_key "admin_user_racial_backgrounds", "racial_backgrounds"
  add_foreign_key "admin_user_salary_windows", "admin_users"
  add_foreign_key "associates_award_agreements", "admin_users"
  add_foreign_key "collective_role_holder_periods", "admin_users"
  add_foreign_key "collective_role_holder_periods", "collective_roles"
  add_foreign_key "contributor_payouts", "admin_users", column: "created_by_id"
  add_foreign_key "contributor_payouts", "invoice_trackers"
  add_foreign_key "creative_lead_periods", "admin_users"
  add_foreign_key "creative_lead_periods", "project_trackers"
  add_foreign_key "creative_lead_periods", "studios"
  add_foreign_key "finalizations", "reviews"
  add_foreign_key "full_time_periods", "admin_users"
  add_foreign_key "gifted_profit_shares", "admin_users"
  add_foreign_key "invoice_trackers", "admin_users"
  add_foreign_key "invoice_trackers", "invoice_passes"
  add_foreign_key "mailing_list_subscribers", "mailing_lists"
  add_foreign_key "mailing_lists", "studios"
  add_foreign_key "okr_period_studios", "okr_periods"
  add_foreign_key "okr_period_studios", "studios"
  add_foreign_key "okr_periods", "okrs"
  add_foreign_key "peer_reviews", "admin_users"
  add_foreign_key "peer_reviews", "reviews"
  add_foreign_key "pre_profit_share_purchases", "admin_users"
  add_foreign_key "profit_share_payments", "admin_users"
  add_foreign_key "profit_share_payments", "profit_share_passes"
  add_foreign_key "project_capsules", "project_trackers"
  add_foreign_key "project_lead_periods", "admin_users"
  add_foreign_key "project_lead_periods", "project_trackers"
  add_foreign_key "project_lead_periods", "studios"
  add_foreign_key "project_safety_representative_periods", "admin_users"
  add_foreign_key "project_safety_representative_periods", "project_trackers"
  add_foreign_key "project_safety_representative_periods", "studios"
  add_foreign_key "project_satisfaction_survey_free_text_question_responses", "project_satisfaction_survey_free_text_questions"
  add_foreign_key "project_satisfaction_survey_free_text_question_responses", "project_satisfaction_survey_responses"
  add_foreign_key "project_satisfaction_survey_free_text_questions", "project_satisfaction_surveys"
  add_foreign_key "project_satisfaction_survey_question_responses", "project_satisfaction_survey_questions"
  add_foreign_key "project_satisfaction_survey_question_responses", "project_satisfaction_survey_responses"
  add_foreign_key "project_satisfaction_survey_questions", "project_satisfaction_surveys"
  add_foreign_key "project_satisfaction_survey_responders", "admin_users"
  add_foreign_key "project_satisfaction_survey_responders", "project_satisfaction_surveys"
  add_foreign_key "project_satisfaction_survey_responses", "project_satisfaction_surveys"
  add_foreign_key "project_satisfaction_surveys", "project_capsules"
  add_foreign_key "project_tracker_forecast_projects", "project_trackers"
  add_foreign_key "project_tracker_forecast_to_runn_sync_tasks", "notifications"
  add_foreign_key "project_tracker_forecast_to_runn_sync_tasks", "project_trackers"
  add_foreign_key "project_tracker_links", "project_trackers"
  add_foreign_key "project_trackers", "runn_projects", primary_key: "runn_id"
  add_foreign_key "qbo_accounts", "enterprises"
  add_foreign_key "qbo_profit_and_loss_reports", "qbo_accounts"
  add_foreign_key "qbo_tokens", "qbo_accounts"
  add_foreign_key "review_trees", "reviews"
  add_foreign_key "review_trees", "trees"
  add_foreign_key "reviews", "admin_users"
  add_foreign_key "score_trees", "trees"
  add_foreign_key "score_trees", "workspaces"
  add_foreign_key "scores", "score_trees"
  add_foreign_key "scores", "traits"
  add_foreign_key "studio_coordinator_periods", "admin_users"
  add_foreign_key "studio_coordinator_periods", "studios"
  add_foreign_key "studio_memberships", "admin_users"
  add_foreign_key "studio_memberships", "studios"
  add_foreign_key "survey_free_text_question_responses", "survey_free_text_questions"
  add_foreign_key "survey_free_text_question_responses", "survey_responses"
  add_foreign_key "survey_free_text_questions", "surveys"
  add_foreign_key "survey_question_responses", "survey_questions"
  add_foreign_key "survey_question_responses", "survey_responses"
  add_foreign_key "survey_questions", "surveys"
  add_foreign_key "survey_responders", "admin_users"
  add_foreign_key "survey_responders", "surveys"
  add_foreign_key "survey_responses", "surveys"
  add_foreign_key "survey_studios", "studios"
  add_foreign_key "survey_studios", "surveys"
  add_foreign_key "system_tasks", "notifications"
  add_foreign_key "team_lead_periods", "admin_users"
  add_foreign_key "team_lead_periods", "project_trackers"
  add_foreign_key "technical_lead_periods", "admin_users"
  add_foreign_key "technical_lead_periods", "project_trackers"
  add_foreign_key "technical_lead_periods", "studios"
  add_foreign_key "traits", "trees"
  add_foreign_key "trueups", "invoice_passes"
end
