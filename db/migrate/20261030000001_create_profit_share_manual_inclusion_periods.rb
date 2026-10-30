class CreateProfitShareManualInclusionPeriods < ActiveRecord::Migration[6.1]
  def change
    create_table :profit_share_manual_inclusion_periods do |t|
      t.references :contributor, null: false, foreign_key: true
      t.date :started_at, null: false
      t.date :ended_at
      t.string :note, null: false
      t.timestamps
    end
  end
end
