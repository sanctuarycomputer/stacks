class Stacks::Notifications
  TWIST_EXCEPTIONS_THREAD_ID = "7718844"

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
    def report_exception(exception)
      exception_hash = {
        message: exception.try(:to_s),
        klass: exception.try(:class).try(:to_s),
        backtrace: exception.try(:backtrace)
      }
      notification = SystemExceptionNotification.with(exception: exception_hash)
      twist.add_comment_to_thread(TWIST_EXCEPTIONS_THREAD_ID, notification.body)
      notification.deliver(System.instance)

      Sentry.capture_exception(exception)
      notification
    end

    def make_notifications!
      Stacks::DataIntegrityManager.new.notify!
    end
  end
end
