class CreateProfitabilityPasses < ActiveRecord::Migration[6.0]
  def change
    create_table :profitability_passes do |t|
      t.jsonb :data

      t.timestamps
    end
  end
end
