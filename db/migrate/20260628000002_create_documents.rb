class CreateDocuments < ActiveRecord::Migration[6.1]
  def change
    create_table :documents do |t|
      t.integer :source, null: false, default: 0
      t.string :external_id, null: false
      t.references :source_record, polymorphic: true, null: true
      t.string :title
      t.string :url
      t.datetime :occurred_at
      t.string :content_hash
      t.integer :excluded, null: false, default: 0
      t.integer :excluded_reason, null: false, default: 0
      t.string :excluded_by
      t.jsonb :raw_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :documents, [:source, :external_id], unique: true
    add_index :documents, :occurred_at
  end
end
