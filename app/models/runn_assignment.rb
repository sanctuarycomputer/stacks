# Nightly mirror of Runn's forward plan (Stacks::Runn#sync_assignments!).
# minutes_per_day applies to each working day in [start_date, end_date]
# (Runn's semantic), except assignments flagged is_non_working_day, which
# cover every calendar day. Pruned by absence on each sync.
class RunnAssignment < ApplicationRecord
  self.primary_key = "runn_id"

  belongs_to :runn_person, foreign_key: :person_id, primary_key: :runn_id, optional: true
  belongs_to :runn_project, foreign_key: :project_id, primary_key: :runn_id, optional: true
  belongs_to :runn_role, foreign_key: :role_id, primary_key: :runn_id, optional: true

  scope :overlapping, ->(from, to) { where("end_date >= ? AND start_date <= ?", from, to) }
  scope :plannable, -> { where(is_template: false, is_active: true) }

  def working_days_between(from, to)
    a = [start_date, from].max
    b = [end_date, to].min
    return 0 if a > b
    return (b - a).to_i + 1 if is_non_working_day
    (a..b).count { |d| (1..5).cover?(d.wday) }
  end

  def hours_between(from, to)
    working_days_between(from, to) * minutes_per_day / 60.0
  end
end
