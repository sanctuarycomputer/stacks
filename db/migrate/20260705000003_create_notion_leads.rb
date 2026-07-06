class CreateNotionLeads < ActiveRecord::Migration[6.1]
  def change
    create_table :notion_leads do |t|
      t.references :notion_page, null: false, foreign_key: true, index: { unique: true }
      t.date :received_at
      t.date :settled_at
      t.date :proposal_sent_at
      t.date :won_at
      t.timestamps
    end

    create_table :notion_lead_studios do |t|
      t.references :notion_lead, null: false, foreign_key: true, index: false
      t.references :studio, null: false, foreign_key: true
      t.timestamps
    end

    add_index :notion_lead_studios, [:notion_lead_id, :studio_id], unique: true
  end
end
