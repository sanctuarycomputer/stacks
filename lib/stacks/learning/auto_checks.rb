module Stacks
  module Learning
    # Things Stacks can verify about a person without asking them. A step of
    # kind "auto_check" names one of these keys.
    module AutoChecks
      # Shared across one refresh_all! run so the Notion mirror is scanned once,
      # not once per person.
      class Context
        def manual_emails
          @manual_emails ||= Stacks::Notion::HumanOperatingManual.all.flat_map(&:emails).to_set
        end
      end

      # owner: who can make the check pass. :person means the person can act on
      # it themselves; :admin means only an admin can (so it is never held
      # against the person).
      CHECKS = {
        "forecast_account" => {
          label: "Has a Harvest Forecast account under their company email",
          owner: :person,
          check: ->(user, _context) { user.forecast_person.present? },
        },
        "payment_profile" => {
          label: "Has a payment profile linked (Deel, or a QuickBooks vendor)",
          owner: :admin,
          check: ->(user, _context) {
            contributor = user.forecast_person&.contributor
            contributor.present? && (contributor.deel_person_id.present? || contributor.contributor_qbo_vendors.exists?)
          },
        },
        "human_operating_manual" => {
          label: "Has a Human Operating Manual in Notion (or is exempt)",
          owner: :person,
          check: ->(user, context) {
            !user.requires_human_operating_manual? || context.manual_emails.include?(user.email.to_s.downcase)
          },
        },
      }.freeze

      def self.keys
        CHECKS.keys
      end

      def self.options_for_select
        CHECKS.map { |key, entry| [entry[:label], key] }
      end

      def self.owner(key)
        CHECKS.dig(key.to_s, :owner) || :person
      end

      # Never raises: a check that blows up counts as "not yet".
      def self.passed?(key, admin_user, context = Context.new)
        entry = CHECKS[key.to_s]
        return false unless entry
        !!entry[:check].call(admin_user, context)
      rescue => e
        Rails.logger.error("Stacks::Learning::AutoChecks #{key} failed for AdminUser##{admin_user&.id}: #{e.class}: #{e.message}")
        Sentry.capture_exception(e) if defined?(Sentry)
        false
      end
    end
  end
end
