class CreateCommissions < ActiveRecord::Migration[6.1]
  def change
    create_table :commissions do |t|
      t.bigint :project_tracker_id, null: false
      t.bigint :contributor_id, null: false
      t.string :type, null: false
      t.decimal :rate, precision: 10, scale: 4, null: false
      t.text :notes
      t.datetime :deleted_at
      t.timestamps precision: 6, null: false
    end

    add_index :commissions, :project_tracker_id
    add_index :commissions, :contributor_id
    add_index :commissions, :deleted_at
    add_index :commissions, :type

    add_foreign_key :commissions, :project_trackers
    add_foreign_key :commissions, :contributors
  end
end
