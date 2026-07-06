class AddQboBillIdToContributorAdjustments < ActiveRecord::Migration[6.1]
  def change
    add_column :contributor_adjustments, :qbo_bill_id, :string
    add_index :contributor_adjustments, :qbo_bill_id
  end
end
