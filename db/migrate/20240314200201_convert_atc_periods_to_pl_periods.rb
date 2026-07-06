class ConvertAtcPeriodsToPlPeriods < ActiveRecord::Migration[6.0]
  def change
    create_table :project_lead_periods do |t|
      t.references :project_tracker, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true
      t.references :studio, null: false, foreign_key: true

      t.date :started_at
      t.date :ended_at

      t.timestamps
    end

    AtcPeriod.all.each do |atcp|      
      ProjectLeadPeriod.create!({
        project_tracker: atcp.project_tracker,
        admin_user: atcp.admin_user,
        studio: atcp.admin_user.studios.first,
        started_at: atcp.started_at,
        ended_at: atcp.ended_at
      })
    end

    drop_table :atc_periods
  end
end
