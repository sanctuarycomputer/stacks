class AddSourceEventsToContacts < ActiveRecord::Migration[6.1]
  def change
    add_column :contacts, :source_events, :jsonb, default: {}, null: false
  end
end
