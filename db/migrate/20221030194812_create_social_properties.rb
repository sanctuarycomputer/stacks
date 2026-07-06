class CreateSocialProperties < ActiveRecord::Migration[6.0]
  def change
    create_table :social_properties do |t|
      t.references :studio, null: false, foreign_key: true
      t.string :profile_url
      t.jsonb :snapshot, default: {}

      t.timestamps
    end
  end
end
