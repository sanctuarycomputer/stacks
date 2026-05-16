class Stacks::Notifications
  TWIST_EXCEPTIONS_THREAD_ID = "7718844"
  TWIST_EXCEPTION_NOTIFY_USER_ID = 427_360

  class << self
    include Rails.application.routes.url_helpers

    def twist
      @_twist ||= Stacks::Twist.new
    end

    def notion
      @_notion ||= Stacks::Notion.new
    end

    def forecast
      @_forecast ||= Stacks::Forecast.new
    end

    # Persists a Notification row for FKs (tasks, reports, etc.) on System — not a user inbox.
    # Alerts go to Sentry + Twist thread only.
    #
    # For Stacks::Errors::Skipped, the notification row is still created (so
    # callers can surface the reason in admin UIs) but Sentry + Twist are
    # suppressed — a skip is an intentional config-driven no-op, not a bug.
    def report_exception(exception)
      exception_hash = {
        message: exception.try(:to_s),
        klass: exception.try(:class).try(:to_s),
        backtrace: exception.try(:backtrace)
      }
      notification = SystemExceptionNotification.with(exception: exception_hash)
      unless exception.is_a?(Stacks::Errors::Skipped)
        twist.add_comment_to_thread(
          TWIST_EXCEPTIONS_THREAD_ID,
          notification.body,
          [TWIST_EXCEPTION_NOTIFY_USER_ID]
        )
      end
      notification.deliver(System.instance)
      Sentry.capture_exception(exception) unless exception.is_a?(Stacks::Errors::Skipped)
      notification
    end

    def make_notifications!
      task_count = Stacks::TaskBuilder.new.task_count
      return if task_count == 0

      SystemNotification.with({
        subject: "#{task_count}x tasks across the team need attention.",
        type: :system,
        link: "https://stacks.garden3d.net/admin/tasks",
        error: :tasks_need_attention,
        priority: 0,
      }).deliver(System.instance)
    end
  end
end
