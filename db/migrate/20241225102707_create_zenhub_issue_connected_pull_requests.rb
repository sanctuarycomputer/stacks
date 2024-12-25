class CreateZenhubIssueConnectedPullRequests < ActiveRecord::Migration[6.0]
  def change
    create_table :zenhub_issue_connected_pull_requests do |t|
      t.string :zenhub_issue_id, null: false
      t.string :zenhub_pull_request_issue_id, null: false
    end
    add_index :zenhub_issue_connected_pull_requests, [:zenhub_issue_id, :zenhub_pull_request_issue_id], unique: true, name: 'idx_zenhub_issue_connected_pull_requests'
  end
end
