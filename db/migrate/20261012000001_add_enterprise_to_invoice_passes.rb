class AddEnterpriseToInvoicePasses < ActiveRecord::Migration[6.1]
  def change
    add_reference :invoice_passes, :enterprise, null: true, foreign_key: true
  end
end
