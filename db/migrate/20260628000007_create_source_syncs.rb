class CreateSourceSyncs < ActiveRecord::Migration[6.1]
  def change
    create_table :source_syncs do |t|
      t.string :source, null: false
      t.jsonb :cursor, null: false, default: {}
      t.datetime :last_run_at
      t.string :status
      t.jsonb :stats, null: false, default: {}
      t.references :system_task, null: true, foreign_key: true
      t.timestamps
    end
    add_index :source_syncs, :source, unique: true
  end
end
