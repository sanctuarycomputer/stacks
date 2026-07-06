class DropUnusedOptixColumns < ActiveRecord::Migration[6.1]
  def change
    # Never populated by sync; the OptixOrganization row is created manually
    # without an optix_id, and nothing references the value.
    remove_index  :optix_organizations, :optix_id, where: "optix_id IS NOT NULL", unique: true, if_exists: true
    remove_column :optix_organizations, :optix_id, :string

    # Never written. Default {} for every row.
    remove_column :optix_organizations, :data, :jsonb, default: {}

    # Optix's User type doesn't expose a first_name field, so the sync never
    # writes it. The User exposes `name` (display) and `surname` (mapped to
    # our last_name); that's the full set of name data available.
    remove_column :optix_users, :first_name, :string

    # Optix's User type doesn't expose a creation timestamp.
    remove_column :optix_users, :created_timestamp, :bigint

    # Optix's Account type isn't a User|Team union, so we never resolved how
    # to dig the right id field out at sync time. Column was always nil.
    # If/when we wire up payer-account tracking, we'll add a fresh column
    # with the appropriate type/name based on what Account actually exposes.
    remove_column :optix_account_plans, :payer_account_optix_id, :string
  end
end
