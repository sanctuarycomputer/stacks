class CreateQboAccounts < ActiveRecord::Migration[6.0]
  def change
    create_table :qbo_accounts do |t|
      t.string :client_id, null: false
      t.string :client_secret, null: false
      t.string :realm_id, null: false
      t.belongs_to :enterprise, null: false, foreign_key: true

      t.timestamps
    end
  end
end
