# TODO: Delete this file and drop ATC Period Table after Project Lead Migration
class AtcPeriod < ApplicationRecord
  include ActsAsPeriod

  belongs_to :project_tracker
  belongs_to :admin_user
  validate :does_not_overlap
  validate :ended_at_before_started_at?

  def period_started_at
    started_at || (project_tracker.first_recorded_assignment && project_tracker.first_recorded_assignment.start_date) || Date.today
  end

  def sibling_periods
    project_tracker.atc_periods
  end
end
