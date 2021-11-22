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

ActiveRecord::Schema.define(version: 2021_11_22_224831) do

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
    t.datetime "archived_at"
    t.boolean "show_skill_tree_data", default: true
    t.integer "old_skill_tree_level"
    t.text "profit_share_notes"
    t.index ["email"], name: "index_admin_users_on_email", unique: true
    t.index ["reset_password_token"], name: "index_admin_users_on_reset_password_token", unique: true
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

  create_table "finalizations", force: :cascade do |t|
    t.bigint "review_id", null: false
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.datetime "deleted_at"
    t.index ["deleted_at"], name: "index_finalizations_on_deleted_at"
    t.index ["review_id"], name: "index_finalizations_on_review_id"
  end

  create_table "full_time_periods", force: :cascade do |t|
    t.bigint "admin_user_id", null: false
    t.date "started_at"
    t.date "ended_at"
    t.decimal "multiplier", default: "1.0"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
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

  create_table "invoice_passes", force: :cascade do |t|
    t.date "start_of_month"
    t.datetime "completed_at"
    t.jsonb "data"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
    t.index ["start_of_month"], name: "index_invoice_passes_on_start_of_month", unique: true
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

  create_table "profitability_passes", force: :cascade do |t|
    t.jsonb "data"
    t.datetime "created_at", precision: 6, null: false
    t.datetime "updated_at", precision: 6, null: false
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

  add_foreign_key "admin_user_communities", "admin_users"
  add_foreign_key "admin_user_communities", "communities"
  add_foreign_key "admin_user_cultural_backgrounds", "admin_users"
  add_foreign_key "admin_user_cultural_backgrounds", "cultural_backgrounds"
  add_foreign_key "admin_user_gender_identities", "admin_users"
  add_foreign_key "admin_user_gender_identities", "gender_identities"
  add_foreign_key "admin_user_racial_backgrounds", "admin_users"
  add_foreign_key "admin_user_racial_backgrounds", "racial_backgrounds"
  add_foreign_key "finalizations", "reviews"
  add_foreign_key "full_time_periods", "admin_users"
  add_foreign_key "gifted_profit_shares", "admin_users"
  add_foreign_key "peer_reviews", "admin_users"
  add_foreign_key "peer_reviews", "reviews"
  add_foreign_key "pre_profit_share_purchases", "admin_users"
  add_foreign_key "review_trees", "reviews"
  add_foreign_key "review_trees", "trees"
  add_foreign_key "reviews", "admin_users"
  add_foreign_key "score_trees", "trees"
  add_foreign_key "score_trees", "workspaces"
  add_foreign_key "scores", "score_trees"
  add_foreign_key "scores", "traits"
  add_foreign_key "traits", "trees"
end
