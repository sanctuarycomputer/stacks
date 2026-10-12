# Wraps a NotionPage row from the Notion Projects database. A project tracker
# names one or many of these as its projects
# (project_trackers.notion_project_ids), and that is how Stacksbot's
# observations find their way to a tracker.
class Stacks::Notion::Project < Stacks::Notion::Base
  # Stages that are live work or live pipeline. Copied from Stacksbot's
  # LIVE_STAGES (scripts/entities/registry.mjs) so the two agree on which
  # projects exist; change them together.
  LIVE_STAGES = [
    "Active", "Ongoing/Maintenance", "Upcoming/Legal Review", "On Hold", "Paused",
    "Project Capsule Needed", "Introduction", "Pre-proposal Questions Needed",
    "Proposal Needed", "Proposal Sent", "Following Up",
  ].freeze
  RECENTLY_COMPLETED = 90.days

  def title
    notion_page.page_title.presence || "Untitled"
  end

  def stage
    notion_page.data.dig("properties", "Stage", "select", "name")
  end

  def duplicated?
    notion_page.data.dig("properties", "🔴 Duplicated", "checkbox") == true
  end

  def live?(now = Time.zone.now)
    return false if duplicated?
    return true if LIVE_STAGES.include?(stage)
    edited = Time.zone.parse(notion_page.data["last_edited_time"].to_s) rescue nil
    stage == "Completed" && edited.present? && edited >= now - RECENTLY_COMPLETED
  end

  # Titles repeat among live projects, so the stage is part of the label.
  def label
    [title, stage].compact.join(" · ")
  end

  # [label, notion_id] pairs for the tracker form: every live project, plus
  # everything this tracker already points at, so saving the form never drops
  # one.
  def self.options_for(tracker)
    options = NotionPage.projects.map(&:as_project).select(&:live?).map { |p| [p.label, p.notion_id] }
    offered = options.map(&:last).to_set
    others = Array(tracker.notion_project_ids).reject { |id| id.blank? || offered.include?(id) }.uniq
    if others.any?
      pages = NotionPage.with_deleted.projects.where(notion_id: others).index_by(&:notion_id)
      others.each do |id|
        page = pages[id]
        options << if page.nil?
          ["Unknown page (removed from Notion)", id]
        elsif page.deleted?
          ["#{page.as_project.title} (removed from Notion)", id]
        else
          [page.as_project.label, id]
        end
      end
    end
    options.sort_by { |(label, _)| label.downcase }
  end
end
