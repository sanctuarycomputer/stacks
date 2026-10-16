class AddIntercompanyBillColumns < ActiveRecord::Migration[6.1]
  # Enterprise name => the "garden3d, LLC" vendor in THAT enterprise's own
  # QuickBooks, verified against production on 2026-10-16. A garden3d invoice
  # to the enterprise is mirrored as a bill from this vendor.
  VENDOR_IDS = {
    "Sanctuary Computer Inc" => "411",
    "Index Space, LLC" => "32",
    "USB Club, LLC" => "200000011",
  }.freeze

  # Migration-local model: no validations, no callbacks, and no dependence on
  # app/models/enterprise.rb as it changes over time.
  class MigrationEnterprise < ActiveRecord::Base
    self.table_name = "enterprises"
  end

  def up
    add_column :enterprises, :g3d_qbo_vendor_id, :string
    # The mirrored bill's id, in the paying enterprise's QuickBooks.
    add_column :invoice_trackers, :payer_qbo_bill_id, :string
    MigrationEnterprise.reset_column_information

    VENDOR_IDS.each do |name, vendor_id|
      # A database without this company (development, CI) updates nothing.
      MigrationEnterprise.where(name: name).update_all(g3d_qbo_vendor_id: vendor_id)
    end
  end

  def down
    remove_column :invoice_trackers, :payer_qbo_bill_id
    remove_column :enterprises, :g3d_qbo_vendor_id
  end
end
