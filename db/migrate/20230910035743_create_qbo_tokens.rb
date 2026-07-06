class CreateQboTokens < ActiveRecord::Migration[6.0]
  def change
    create_table :qbo_tokens do |t|
      t.string :token, null: false
      t.string :refresh_token, null: false
      t.belongs_to :qbo_account, null: false, foreign_key: true

      t.timestamps
    end
  end
end
