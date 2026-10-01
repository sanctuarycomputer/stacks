module Stacks
  class TaskBuilder
    module Discoveries
      # Every active admin should have a Human Operating Manual page in
      # Notion (matched by email) with a Pigment.is Superpowers PDF attached,
      # unless an admin has exempted them via AdminUser's
      # requires_human_operating_manual / requires_superpowers_assessment
      # flags (both default true).
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
              # Exempt from the manual entirely: nothing to nag about, and there
              # is no manual on which a Superpowers assessment could live, so an
              # outstanding assessment requirement is unactionable here too.
              next [] unless user.requires_human_operating_manual?
              [task(subject: user, type: :missing_human_operating_manual, owners: [user])]
            elsif manuals.none?(&:superpowers_pdf?)
              next [] unless user.requires_superpowers_assessment?
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
