class CreateGoogleGroupThreads < ActiveRecord::Migration[6.1]
  def change
    create_table :google_group_threads do |t|
      t.string :group_email
      t.string :list_id
      t.string :subject
      t.string :root_message_id, null: false
      t.integer :message_count, null: false, default: 0
      t.datetime :first_message_at
      t.datetime :last_message_at
      t.timestamps
    end
    add_index :google_group_threads, :root_message_id, unique: true
    add_index :google_group_threads, :group_email
  end
end
