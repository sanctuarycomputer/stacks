module Stacks
  class TaskBuilder
    module Discoveries
      class NotionLeads < Base
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

          out
        end
      end
    end
  end
end
