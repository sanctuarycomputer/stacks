# Where a project's conversation lives, for the project log:
# the Notion Projects page it belongs to, and whether the Stacksbot Twist
# account can see the tracker's Twist channel (nil = not checked yet).
class AddProjectSourcesToProjectTrackers < ActiveRecord::Migration[6.1]
  def change
    add_column :project_trackers, :notion_project_id, :string
    add_column :project_trackers, :twist_channel_accessible, :boolean
    add_column :project_trackers, :twist_channel_checked_at, :datetime
    add_index :project_trackers, :notion_project_id
  end
end
