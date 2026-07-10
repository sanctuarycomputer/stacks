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

    # How many deactivated emails to list before truncating — skips/errors
    # are always listed in full (they're the actionable part).
    OPTIX_DEACTIVATION_LIST_CAP = 50

    # Posts a summary of an Optix inactive-member deactivation run
    # (Stacks::Optix::DeactivateInactiveMembers::Result) to the same Twist
    # thread + notify-user as exceptions. Skipped members need manual
    # handling in Optix, and Heroku's log retention is too short to rely on —
    # this is their durable surface. Silent when the run did nothing.
    def report_optix_deactivation_run(result)
      return if result.deactivated.empty? && result.skipped.empty? && result.errors.empty?

      twist.add_comment_to_thread(
        TWIST_EXCEPTIONS_THREAD_ID,
        optix_deactivation_body(result),
        [TWIST_EXCEPTION_NOTIFY_USER_ID]
      )
    end

    def optix_deactivation_body(result)
      lines = []
      lines << "**Optix inactive-member deactivation run**"
      lines << "#{result.deactivated.length} deactivated, #{result.skipped.length} skipped, #{result.errors.length} errored."

      if result.deactivated.any?
        shown = result.deactivated.first(OPTIX_DEACTIVATION_LIST_CAP)
        line = "**Deactivated:** #{shown.map { |d| d[:email] }.join(", ")}"
        overflow = result.deactivated.length - shown.length
        line += " (+#{overflow} more)" if overflow.positive?
        lines << line
      end

      if result.skipped.any?
        lines << "**Skipped (needs manual handling in Optix):**"
        result.skipped.each { |s| lines << "- #{s[:email]} — #{s[:reason]}" }
      end

      if result.errors.any?
        lines << "**Errors (will retry tomorrow):**"
        result.errors.each { |e| lines << "- #{e[:email]} — #{e[:error]}" }
      end

      lines.join("\n")
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
