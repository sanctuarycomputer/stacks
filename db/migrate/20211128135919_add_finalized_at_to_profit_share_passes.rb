class AddFinalizedAtToProfitSharePasses < ActiveRecord::Migration[6.0]
  def change
    add_column :profit_share_passes, :finalized_at, :datetime
  end
end
