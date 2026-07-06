class CreateUtilizationPasses < ActiveRecord::Migration[6.0]
  def change
    create_table :utilization_passes do |t|
      t.jsonb :data

      t.timestamps
    end
  end
end
