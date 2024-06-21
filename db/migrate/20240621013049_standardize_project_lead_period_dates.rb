class StandardizeProjectLeadPeriodDates < ActiveRecord::Migration[6.0]
  def update_started_at!(lead_period)
    return unless lead_period.started_at.nil?

    started_at = if project_tracker.first_recorded_assignment.present?
      project_tracker.first_recorded_assignment.start_date
    else
      project_tracker.created_at
    end

    lead_period.update!({
      started_at: started_at
    })
  end

  def update_ended_at!(lead_period)
    return unless lead_period.ended_at.nil?
    return unless project_tracker.work_complete?

    ended_at = if project_tracker.last_recorded_assignment.present?
      project_tracker.last_recorded_assignment.end_date
    else
      project_tracker.work_completed_at
    end

    lead_period.update!({
      ended_at: ended_at
    })
  end

  def change
    ProjectLeadPeriod.all.each do |lead_period|
      update_started_at!(lead_period)
      update_ended_at!(lead_period)
    end

    change_column_null :project_lead_periods, :started_at, false
  end
end
