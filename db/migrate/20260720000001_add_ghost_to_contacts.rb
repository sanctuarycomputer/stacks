class AddGhostToContacts < ActiveRecord::Migration[6.1]
  def change
    add_column :contacts, :ghost_id, :string
    add_index :contacts, :ghost_id, unique: true
    add_column :contacts, :ghost_data, :jsonb, default: {}, null: false
  end
end
