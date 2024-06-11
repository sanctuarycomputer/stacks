class AddApolloDataToContacts < ActiveRecord::Migration[6.0]
  def change
    add_column :contacts, :apollo_data, :jsonb, default: {}
  end
end
