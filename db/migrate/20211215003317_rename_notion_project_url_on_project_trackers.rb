class RenameNotionProjectUrlOnProjectTrackers < ActiveRecord::Migration[6.0]
  def change
    rename_column :project_trackers, :notion_project_url, :notion_proposal_url
  end
end
