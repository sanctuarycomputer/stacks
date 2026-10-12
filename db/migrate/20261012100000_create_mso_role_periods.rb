class CreateMsoRolePeriods < ActiveRecord::Migration[6.1]
  def change
    create_table :mso_role_periods do |t|
      t.references :contributor, null: false, foreign_key: true
      t.integer :tier, null: false
      t.string :title, null: false
      t.date :started_at, null: false
      t.date :ended_at
      t.timestamps
    end
  end
end
