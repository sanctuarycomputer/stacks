class CreateAtcPeriods < ActiveRecord::Migration[6.0]
  def change
    create_table :atc_periods do |t|
      t.references :project_tracker, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true
      t.date :started_at
      t.date :ended_at

      t.timestamps
    end

    ProjectTracker.all.each do |pt|
      if pt.atc.present?
        AtcPeriod.create!({
          project_tracker: pt,
          admin_user: pt.atc,
          started_at: nil,
          ended_at: nil
        })
      end
    end

    remove_reference :project_trackers, :atc, foreign_key: { to_table: :admin_users }
  end
end
