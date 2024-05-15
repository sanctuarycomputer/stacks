class AddApolloIdToContacts < ActiveRecord::Migration[6.0]
  def change
    add_column :contacts, :apollo_id, :string
    add_index :contacts, :apollo_id, unique: true
  end
end
