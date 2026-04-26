module Stacks
  class TaskBuilder
    module Discoveries
      class NotionLeads < Base
        def tasks
          all_leads = NotionPage.lead.map(&:as_lead)

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
