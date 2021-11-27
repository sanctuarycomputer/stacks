class CreateDeiRollups < ActiveRecord::Migration[6.0]
  def change
    create_table :dei_rollups do |t|
      t.jsonb :data

      t.timestamps
    end
  end
end
