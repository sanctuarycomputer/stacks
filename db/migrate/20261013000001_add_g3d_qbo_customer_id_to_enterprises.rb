class AddG3dQboCustomerIdToEnterprises < ActiveRecord::Migration[6.1]
  # Enterprise name => that company's customer id in garden3d's QuickBooks
  # (realm 9130355602868216), verified against production on 2026-10-09.
  # garden3d invoices every enterprise that has one stored. USB Club has no
  # customer there yet; store its id once Finance creates it.
  CUSTOMER_IDS = {
    "Sanctuary Computer Inc" => "2",
    "Index Space, LLC" => "5",
  }.freeze

  # Migration-local model: no validations, no callbacks, and no dependence on
  # app/models/enterprise.rb as it changes over time.
  class MigrationEnterprise < ActiveRecord::Base
    self.table_name = "enterprises"
  end

  def up
    add_column :enterprises, :g3d_qbo_customer_id, :string
    MigrationEnterprise.reset_column_information

    CUSTOMER_IDS.each do |name, customer_id|
      # A database without this company (development, CI) updates nothing.
      MigrationEnterprise.where(name: name).update_all(g3d_qbo_customer_id: customer_id)
    end
  end

  def down
    remove_column :enterprises, :g3d_qbo_customer_id
  end
end
