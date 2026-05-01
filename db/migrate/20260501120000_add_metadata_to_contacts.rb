class AddMetadataToContacts < ActiveRecord::Migration[6.1]
  def up
    return if column_exists?(:contacts, :metadata)

    add_column :contacts, :metadata, :jsonb, null: false, default: {}
  end

  def down
    return unless column_exists?(:contacts, :metadata)

    remove_column :contacts, :metadata
  end
end
