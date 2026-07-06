class CreateMentions < ActiveRecord::Migration[6.1]
  def change
    create_table :mentions do |t|
      t.references :chunk, null: false, foreign_key: true
      t.string :raw_text, null: false
      t.references :contact, null: true, foreign_key: true
      t.float :confidence
      t.integer :status, null: false, default: 0
      t.timestamps
    end
  end
end
