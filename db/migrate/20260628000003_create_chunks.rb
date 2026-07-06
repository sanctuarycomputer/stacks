class CreateChunks < ActiveRecord::Migration[6.1]
  def change
    create_table :chunks do |t|
      t.references :document, null: false, foreign_key: true
      t.integer :position, null: false
      t.text :content, null: false
      t.integer :start_offset
      t.integer :end_offset
      t.string :speaker_name
      t.references :speaker_contact, null: true, foreign_key: { to_table: :contacts }
      t.integer :source, null: false, default: 0
      t.datetime :occurred_at
      t.timestamps
    end
    execute "ALTER TABLE chunks ADD COLUMN content_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED"
    execute "CREATE INDEX index_chunks_on_content_tsv ON chunks USING gin (content_tsv)"
    add_index :chunks, [:document_id, :position], unique: true
  end
end
