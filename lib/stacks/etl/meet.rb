module Stacks
  module Etl
    module Meet
      # Runs the Meet connector for EVERY active Workspace user, impersonating each in
      # turn. Per-user failures (no license, revoked access, no transcripts) are caught
      # and logged so one bad user never aborts the org-wide sweep. Wrapped in a
      # SystemTask for observability, matching the rest of the app's scheduled jobs.
      #
      #   mode:  :drive (Drive transcript backfill) or :api (Meet REST API, recent)
      #   since: lower time bound passed to each user's connector run
      def self.sweep_all_users!(task_name:, mode:, since:, until_time: nil)
        system_task = SystemTask.create!(name: task_name)
        emails = Workspace.all_active_user_emails
        ok = 0
        failed = []

        emails.each do |email|
          # track:false so per-user runs don't clobber the shared :meet cursor.
          Connector.new(admin_email: email, mode: mode, until_time: until_time).run(since: since, track: false)
          ok += 1
        rescue StandardError => e
          failed << "#{email}: #{e.class}: #{e.message.to_s[0, 140]}"
        end

        Rails.logger.info("[#{task_name}] #{ok}/#{emails.size} users ok, #{failed.size} failed")
        failed.first(25).each { |f| Rails.logger.warn("[#{task_name}] FAIL #{f}") }

        # A total failure (e.g. org-wide auth broken) must NOT report green.
        if ok.zero? && emails.any?
          system_task.mark_as_error(RuntimeError.new("#{task_name}: all #{emails.size} users failed; first: #{failed.first(3).join(' | ')}"))
        else
          system_task.mark_as_success
        end
        { ok: ok, failed: failed.size, total: emails.size }
      rescue StandardError => e
        system_task&.mark_as_error(e)
        raise
      end
    end
  end
end
