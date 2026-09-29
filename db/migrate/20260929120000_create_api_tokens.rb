# Scoped API tokens for the Stacks API and MCP surfaces. Only a SHA-256 digest of each token is stored; the
# plaintext is shown once, at mint. The app tolerates this table being missing (deploys land before
# migrations on Heroku): until it exists, only the legacy shared key is accepted.
class CreateApiTokens < ActiveRecord::Migration[6.1]
  def change
    create_table :api_tokens do |t|
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.string :scopes, array: true, null: false, default: []
      t.references :created_by, foreign_key: { to_table: :admin_users }, null: true
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.datetime :expires_at
      t.timestamps
    end
    add_index :api_tokens, :token_digest, unique: true
  end
end
