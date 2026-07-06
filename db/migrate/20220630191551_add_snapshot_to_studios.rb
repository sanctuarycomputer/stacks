class AddSnapshotToStudios < ActiveRecord::Migration[6.0]
  def change
    add_column :studios, :snapshot, :jsonb, default: {}
  end
end
