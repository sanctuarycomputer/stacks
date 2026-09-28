module Stacks
  class TaskBuilder
    module Discoveries
      class NotionLeads < Base
        # Loss surveys are owed only for leads lost on or after this date, so
        # rolling the task out doesn't dump years of history on the sellers.
        LOSS_SURVEYS_FROM = Date.new(2026, 8, 1)

        def tasks
          all_leads = NotionPage.lead.map(&:as_lead)

          # Bulk-resolve every lead's Account Lead admin users in ONE query
          # rather than N. Each lead reads from the shared cache.
          all_emails = all_leads.flat_map(&:account_lead_emails).uniq
          admin_users_by_email =
            if all_emails.any?
              AdminUser.where("LOWER(email) IN (?)", all_emails).index_by { |au| au.email.downcase }
            else
              {}
            end
          all_leads.each { |l| l.account_lead_admin_users_cache = admin_users_by_email }

          all_leads.flat_map do |lead|
            owners = lead.account_lead_admin_users
            issues_for(lead).map do |type|
              task(subject: lead, type: type, owners: owners)
            end
          end
        end

        private

        def issues_for(lead)
          out = []
          out << :no_received_at_timestamp_set if lead.received_at.blank?

          if lead.age.present? && lead.age > 60 && lead.age < 365 && lead.settled_at.nil?
            unless lead.reactivate_at && Date.parse(lead.reactivate_at) > Date.today
              out << :needs_settling
            end
          end

          studios = lead.studios
          out << :no_studios_set if studios.blank?

          out << :needs_budget_estimate if lead.open? && lead.estimated_budget.nil?

          out << :loss_survey_needed if loss_survey_needed?(lead)

          out
        end

        # A Lost lead (the client chose someone else) that saw a proposal and
        # hasn't had its survey dealt with. Passed leads are excluded: we
        # declined those, and the survey asks why they went with another vendor.
        def loss_survey_needed?(lead)
          return false unless lead.lead_status == "Lost"
          return false if lead.lost_at.blank? || Date.parse(lead.lost_at) < LOSS_SURVEYS_FROM
          return false if lead.proposal_sent_at.blank? || lead.no_proposal_sent?
          !lead.loss_survey_handled?
        end
      end
    end
  end
end
