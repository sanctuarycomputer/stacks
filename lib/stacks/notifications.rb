class Stacks::Notifications
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

    def report_exception(exception)
      notification = SystemExceptionNotification.with(
        exception: {
          message: exception.try(:to_s),
          klass: exception.try(:class).try(:to_s),
          backtrace: exception.try(:backtrace)
        },
        include_admins: false,
      )
      notification.deliver(AdminUser.find_by(email: "hugh@sanctuary.computer"))

      Sentry.capture_exception(exception)
      notification
    end

    def make_notifications!
      Stacks::DataIntegrityManager.new.notify!
    end
  end
end
