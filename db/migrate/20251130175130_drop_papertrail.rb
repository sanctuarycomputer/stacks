class DropPapertrail < ActiveRecord::Migration[6.1]
  def change
    drop_table :versions
  end
end
