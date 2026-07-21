class AddGhostToContacts < ActiveRecord::Migration[6.1]
  def change
    add_column :contacts, :ghost_id, :string
    add_index :contacts, :ghost_id, unique: true
    add_column :contacts, :ghost_data, :jsonb, default: {}, null: false

    create_table :ghost_synced_sources do |t|
      t.string :source, null: false
      t.timestamps
    end
    add_index :ghost_synced_sources, :source, unique: true
  end
end
