class CreateReimbursements < ActiveRecord::Migration[6.1]
  def change
    create_table :reimbursements do |t|
      t.references :contributor, null: false
      t.decimal :amount, precision: 10, scale: 2, null: false
      t.string :description, null: false
      t.text :receipts, null: false
      t.references :accepted_by, foreign_key: { to_table: :admin_users }
      t.datetime :accepted_at
      t.datetime :deleted_at
      t.timestamps
    end

    add_index :reimbursements, :deleted_at
  end
end
