class DropNotionProposalFromProjectTrackers < ActiveRecord::Migration[6.0]
  def change
    ProjectTracker.all.each do |pt|
      if pt.notion_proposal_url.present?
        ProjectTrackerLink.create!(
          name: "Proposal",
          url: pt.notion_proposal_url,
          link_type: :proposal,
          project_tracker: pt
        )
      end
    end

    remove_column :project_trackers, :notion_proposal_url
  end
end
