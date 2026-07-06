class CreateMailingListSubscribers < ActiveRecord::Migration[6.0]
  def change
    create_table :mailing_list_subscribers do |t|
      t.references :mailing_list, null: false, foreign_key: true
      t.string :email, null: false
      t.jsonb :info, null: false, default: '{}'
    end

    add_index :mailing_list_subscribers, [:mailing_list_id, :email], unique: true
  end
end
