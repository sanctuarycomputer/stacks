class AddManagementFeePayerToEnterprises < ActiveRecord::Migration[6.1]
  # Enterprise name => that company's customer id in garden3d's QuickBooks
  # (realm 9130355602868216), verified against production on 2026-10-09.
  # USB Club has no customer there yet: Stacks creates one the first time an
  # admin pushes its draft, and stores the id then.
  PAYERS = {
    "Sanctuary Computer Inc" => "2",
    "Index Space, LLC" => "5",
    "USB Club, LLC" => nil,
  }.freeze

  # Migration-local model: no validations, no callbacks, and no dependence on
  # app/models/enterprise.rb as it changes over time.
  class PayerEnterprise < ActiveRecord::Base
    self.table_name = "enterprises"
  end

  def up
    add_column :enterprises, :management_fee_payer, :boolean, null: false, default: false
    add_column :enterprises, :g3d_qbo_customer_id, :string
    seed_payers!
  end

  # Rolling back drops any customer id Stacks stored after CREATING a customer
  # (USB Club's). Re-migrating then leaves that id blank again. That is safe:
  # with a blank id, Mso::ManagementFeeInvoices refuses to create a customer
  # when an active one already has the payer's exact name, and names its id so
  # it can be stored by hand. It does not create a duplicate.
  def down
    remove_column :enterprises, :g3d_qbo_customer_id
    remove_column :enterprises, :management_fee_payer
  end

  # Public so the test can run the seed against the schema-loaded test
  # database, where the columns already exist. Safe to run twice.
  def seed_payers!
    PayerEnterprise.reset_column_information

    PAYERS.each do |name, customer_id|
      enterprise = PayerEnterprise.find_by(name: name)
      next if enterprise.nil? # a database without this company (development, CI)

      attrs = { management_fee_payer: true }
      attrs[:g3d_qbo_customer_id] = customer_id if customer_id && enterprise.g3d_qbo_customer_id.blank?
      enterprise.update_columns(attrs)
    end
  end
end
