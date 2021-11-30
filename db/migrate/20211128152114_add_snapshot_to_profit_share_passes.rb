class AddSnapshotToProfitSharePasses < ActiveRecord::Migration[6.0]
  def change
    add_column :profit_share_passes, :snapshot, :jsonb
  end
end
