class CreateQuickbooksTokens < ActiveRecord::Migration[6.0]
  def change
    create_table :quickbooks_tokens do |t|
      t.string :token
      t.string :refresh_token

      t.timestamps
    end
  end
end
