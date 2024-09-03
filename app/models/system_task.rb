class SystemTask < ApplicationRecord
  scope :in_progress, -> {
    where(settled_at: nil)
  }
  scope :success, -> {
    where.not(settled_at: nil).where(notification: nil)
  }
  scope :error, -> {
    where.not(notification: nil, settled_at: nil)
  }

  belongs_to :notification, optional: true

  def time_taken
    return Float::INFINITY if settled_at.nil?
    settled_at - created_at
  end

  def mark_as_success
    update(settled_at: DateTime.now, notification: nil)
  end

  def mark_as_error(e)
    notification = Stacks::Notifications.report_exception(e)
    update(settled_at: DateTime.now, notification: notification.record)
  end
end
