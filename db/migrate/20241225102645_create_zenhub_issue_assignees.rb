class CreateZenhubIssueAssignees < ActiveRecord::Migration[6.0]
  def change
    create_table :zenhub_issue_assignees do |t|
      t.string :zenhub_issue_id, null: false
      t.integer :github_user_id, null: false
    end
    add_index :zenhub_issue_assignees, [:zenhub_issue_id, :github_user_id], unique: true, name: 'idx_zenhub_issue_assignees'
  end
end
