class CreateMailingLists < ActiveRecord::Migration[6.0]
  def change
    create_table :mailing_lists do |t|
      t.string :name, null: false
      t.references :studio, null: false, foreign_key: true
      t.jsonb :snapshot, null: false, default: {}
      t.integer :provider, default: 0, null: false

      t.timestamps
    end
  end
end
