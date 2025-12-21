class SystemTask < ApplicationRecord
  scope :in_progress, -> {
    where(settled_at: nil)
  }
  scope :success, -> {
    where("settled_at IS NOT NULL AND notification_id IS NULL")
  }
  scope :error, -> {
    where("notification_id IS NOT NULL AND settled_at IS NOT NULL")
  }

  belongs_to :notification, optional: true, dependent: :destroy

  def self.clean_up_old_tasks!
    where("created_at < ?", 1.week.ago).delete_all
  end

  def time_taken_in_minutes
    return Float::INFINITY if settled_at.nil?
    (settled_at - created_at).to_i / 60.0
  end

  def mark_as_success
    update(settled_at: DateTime.now, notification: nil)
  end

  def mark_as_error(e)
    notification = Stacks::Notifications.report_exception(e)
    update(settled_at: DateTime.now, notification: notification.record)
  end
end
