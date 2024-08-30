class CreateTechnicalLeadPeriods < ActiveRecord::Migration[6.0]
  def change
    create_table :technical_lead_periods do |t|
      t.references :project_tracker, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true
      t.references :studio, null: false, foreign_key: true

      t.date :started_at
      t.date :ended_at
      t.timestamps
    end
  end
end
