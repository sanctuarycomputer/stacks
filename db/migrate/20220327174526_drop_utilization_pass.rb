class DropUtilizationPass < ActiveRecord::Migration[6.0]
  def change
    drop_table :utilization_passes
  end
end
