class CreateProjectSafetyRepresentativePeriods < ActiveRecord::Migration[6.0]
  def change
    create_table :project_safety_representative_periods do |t|
      t.references :project_tracker, null: false, foreign_key: true, index: { name: 'idx_project_safety_rep_periods_on_project_tracker_id' }
      t.references :admin_user, null: false, foreign_key: true, index: { name: 'idx_project_safety_rep_periods_on_admin_user_id' }
      t.references :studio, null: false, foreign_key: true, index: { name: 'idx_project_safety_rep_periods_on_studio_id' }

      t.date :started_at
      t.date :ended_at

      t.timestamps
    end
  end
end
