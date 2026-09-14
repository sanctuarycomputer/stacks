module Stacks
  class TaskBuilder
    module Discoveries
      # Every active admin should have a Human Operating Manual page in
      # Notion (matched by email) with a Pigment.is Superpowers PDF attached.
      # Both task types are personal — owned by the admin themselves.
      class HumanOperatingManuals < Base
        def tasks
          # An entirely-empty scope means the database has never been synced
          # (the real Notion database is populated) — e.g. freshly deployed
          # before the first stacks:sync_notion run. Emitting tasks then would
          # falsely nag every active admin, so stay silent until data arrives.
          return [] if NotionPage.human_operating_manual.none?

          manuals_by_email = Hash.new { |h, k| h[k] = [] }
          Stacks::Notion::HumanOperatingManual.all.each do |manual|
            manual.emails.each { |e| manuals_by_email[e] << manual }
          end

          AdminUser.active.not_ignored.distinct.flat_map do |user|
            manuals = manuals_by_email[user.email.downcase]
            if manuals.empty?
              [task(subject: user, type: :missing_human_operating_manual, owners: [user])]
            elsif manuals.none?(&:superpowers_pdf?)
              # Deterministic subject across cache rebuilds: lowest NotionPage id.
              manual = manuals.min_by { |m| m.notion_page.id.to_i }
              [task(subject: manual, type: :missing_superpowers_pdf, owners: [user])]
            else
              []
            end
          end
        end
      end
    end
  end
end
