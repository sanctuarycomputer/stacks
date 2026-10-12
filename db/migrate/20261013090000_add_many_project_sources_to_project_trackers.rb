# A tracker may name several Notion Projects pages and several Twist channels:
# notion_project_ids replaces notion_project_id, and twist_channels_inaccessible
# (the channels the Stacksbot Twist account was not in at the last check)
# replaces twist_channel_accessible.
#
# This runs on production while the code before it is still live, and that
# code reads and writes the two old columns, so they are left in place here
# and dropped in a follow-up. Safe to run twice.
class AddManyProjectSourcesToProjectTrackers < ActiveRecord::Migration[6.1]
  def up
    unless column_exists?(:project_trackers, :notion_project_ids)
      add_column :project_trackers, :notion_project_ids, :string, array: true, default: [], null: false
    end
    unless column_exists?(:project_trackers, :twist_channels_inaccessible)
      add_column :project_trackers, :twist_channels_inaccessible, :bigint, array: true, default: [], null: false
    end

    # The same statement as rake stacks:backfill_notion_project_ids, which
    # picks up a choice the old code saves between this migration and the
    # deploy. Only fills an empty array, so it never undoes a newer choice.
    if column_exists?(:project_trackers, :notion_project_id)
      execute <<~SQL
        UPDATE project_trackers
        SET notion_project_ids = ARRAY[btrim(notion_project_id)]
        WHERE notion_project_id IS NOT NULL
          AND btrim(notion_project_id) <> ''
          AND cardinality(notion_project_ids) = 0
      SQL
    end
  end

  # The old columns were never touched, so there is nothing to copy back.
  def down
    remove_column :project_trackers, :notion_project_ids if column_exists?(:project_trackers, :notion_project_ids)
    remove_column :project_trackers, :twist_channels_inaccessible if column_exists?(:project_trackers, :twist_channels_inaccessible)
  end
end
