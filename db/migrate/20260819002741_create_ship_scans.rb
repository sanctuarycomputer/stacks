class CreateShipScans < ActiveRecord::Migration[6.1]
  def change
    create_table :ship_scans do |t|
      t.references :document, null: false, foreign_key: true, index: { unique: true }
      t.integer :outcome, null: false
      t.string :scanned_content_hash
      t.datetime :scanned_at, null: false
      t.boolean :human_locked, null: false, default: false
      t.timestamps
    end
  end
end
