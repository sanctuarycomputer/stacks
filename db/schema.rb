# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `rails
# db:schema:load`. When creating a new database, `rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema.define(version: 2023_09_08_034804) do

  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

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
    t.index ["qbo_invoice_id"], name: "index_adhoc_invoice_trackers_on_qbo_invoice_id", unique: true
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
    t.index ["email"], name: "index_admin_users_on_email", unique: true
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

  create_table "atc_periods", force: :cascade do |t|
    t.bigint "project_tracker_id", null: false
    t.bigint "admin_user_id", null: false
    t.date "started_at"
    t.date "ended_at"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["admin_user_id"], name: "index_atc_periods_on_admin_user_id"
    t.index ["project_tracker_id"], name: "index_atc_periods_on_project_tracker_id"
  end

  create_table "budgets", force: :cascade do |t|
    t.string "name", null: false
    t.text "notes"
    t.decimal "amount", default: "0.0", null: false
    t.integer "budget_type", default: 0, null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "communities", force: :cascade do |t|
    t.string "name"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "cultural_backgrounds", force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.boolean "opt_out"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "dei_rollups", force: :cascade do |t|
    t.jsonb "data"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "expense_groups", force: :cascade do |t|
    t.string "name"
    t.string "matcher"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["matcher"], name: "index_expense_groups_on_matcher", unique: true
    t.index ["name"], name: "index_expense_groups_on_name", unique: true
  end

  create_table "finalizations", force: :cascade do |t|
    t.bigint "review_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.datetime "deleted_at"
    t.index ["deleted_at"], name: "index_finalizations_on_deleted_at"
    t.index ["review_id"], name: "index_finalizations_on_review_id"
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
    t.index ["forecast_id"], name: "index_forecast_assignments_on_forecast_id", unique: true
    t.index ["person_id"], name: "index_forecast_assignments_on_person_id"
    t.index ["project_id"], name: "index_forecast_assignments_on_project_id"
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
    t.index ["admin_user_id"], name: "index_invoice_trackers_on_admin_user_id"
    t.index ["forecast_client_id", "invoice_pass_id"], name: "idx_invoice_trackers_on_forecast_client_id_and_invoice_pass_id", unique: true
    t.index ["forecast_client_id"], name: "index_invoice_trackers_on_forecast_client_id"
    t.index ["invoice_pass_id"], name: "index_invoice_trackers_on_invoice_pass_id"
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

  create_table "pre_spent_budgetary_purchases", force: :cascade do |t|
    t.decimal "amount", null: false
    t.string "note"
    t.date "spent_at", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.bigint "budget_id"
    t.index ["budget_id"], name: "index_pre_spent_budgetary_purchases_on_budget_id"
  end

  create_table "profit_share_passes", force: :cascade do |t|
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.decimal "payroll_buffer_months", default: "1.5"
    t.decimal "efficiency_cap", default: "1.6"
    t.jsonb "snapshot"
    t.decimal "internals_budget_multiplier", default: "0.5"
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
    t.index ["project_tracker_id"], name: "index_project_capsules_on_project_tracker_id"
  end

  create_table "project_tracker_forecast_projects", force: :cascade do |t|
    t.bigint "project_tracker_id", null: false
    t.bigint "forecast_project_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["forecast_project_id"], name: "index_project_tracker_forecast_projects_on_forecast_project_id"
    t.index ["project_tracker_id"], name: "index_project_tracker_forecast_projects_on_project_tracker_id"
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

  create_table "project_trackers", force: :cascade do |t|
    t.string "name"
    t.decimal "budget_low_end"
    t.decimal "budget_high_end"
    t.text "notes"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.datetime "work_completed_at"
    t.jsonb "snapshot", default: {}
  end

  create_table "qbo_invoices", force: :cascade do |t|
    t.string "qbo_id", null: false
    t.jsonb "data"
    t.index ["qbo_id"], name: "index_qbo_invoices_on_qbo_id", unique: true
  end

  create_table "qbo_profit_and_loss_reports", force: :cascade do |t|
    t.date "starts_at", null: false
    t.date "ends_at", null: false
    t.jsonb "data", default: "{}"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
  end

  create_table "qbo_purchase_line_items", id: :string, force: :cascade do |t|
    t.date "txn_date"
    t.string "qbo_purchase_id"
    t.string "description"
    t.float "amount"
    t.bigint "expense_group_id"
    t.jsonb "data", default: {}
    t.index ["expense_group_id"], name: "index_qbo_purchase_line_items_on_expense_group_id"
    t.index ["id"], name: "index_qbo_purchase_line_items_on_id", unique: true
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

  create_table "social_properties", force: :cascade do |t|
    t.bigint "studio_id", null: false
    t.string "profile_url"
    t.jsonb "snapshot", default: {}
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["studio_id"], name: "index_social_properties_on_studio_id"
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
  end

  create_table "systems", force: :cascade do |t|
    t.jsonb "settings"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
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
  add_foreign_key "associates_award_agreements", "admin_users"
  add_foreign_key "atc_periods", "admin_users"
  add_foreign_key "atc_periods", "project_trackers"
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
  add_foreign_key "project_capsules", "project_trackers"
  add_foreign_key "project_tracker_forecast_projects", "project_trackers"
  add_foreign_key "project_tracker_links", "project_trackers"
  add_foreign_key "qbo_purchase_line_items", "expense_groups"
  add_foreign_key "review_trees", "reviews"
  add_foreign_key "review_trees", "trees"
  add_foreign_key "reviews", "admin_users"
  add_foreign_key "score_trees", "trees"
  add_foreign_key "score_trees", "workspaces"
  add_foreign_key "scores", "score_trees"
  add_foreign_key "scores", "traits"
  add_foreign_key "social_properties", "studios"
  add_foreign_key "studio_coordinator_periods", "admin_users"
  add_foreign_key "studio_coordinator_periods", "studios"
  add_foreign_key "studio_memberships", "admin_users"
  add_foreign_key "studio_memberships", "studios"
  add_foreign_key "traits", "trees"
end
