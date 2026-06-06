class CreateLedgerWithdrawalRequests < ActiveRecord::Migration[6.1]
  def change
    create_table :ledger_withdrawal_requests do |t|
      t.references :ledger, null: false, foreign_key: true
      t.datetime :requested_at, null: false
      t.datetime :processed_at
      t.datetime :cancelled_at
      t.references :cancelled_by, foreign_key: { to_table: :admin_users }
      t.text :cancelled_reason
      t.text :notes
      # How the controller resolved the request, set when processed_at flips.
      # One of: "deel", "qbo_bill_pay", "manual".
      t.string :paid_via
      t.bigint :deel_invoice_adjustment_id
      t.timestamps
    end
    add_index :ledger_withdrawal_requests, :processed_at
    add_index :ledger_withdrawal_requests, :cancelled_at

    create_table :ledger_withdrawal_request_bills do |t|
      t.references :ledger_withdrawal_request, null: false, foreign_key: true, index: { name: "idx_lwrb_on_request_id" }
      # Bills are identified by (qbo_account_id, qbo_id) — same composite key
      # the rest of the QBO-side records use. Storing both lets us go straight
      # to QboBill.find_by(qbo_account_id:, qbo_id:) without an extra join.
      t.bigint :qbo_account_id, null: false
      t.string :qbo_bill_id, null: false
      # Snapshot of the Bill's amount at request time so the show page and
      # totals stay stable even if a QBO-side edit changes the live amount.
      t.decimal :amount_snapshot, precision: 12, scale: 2, null: false
      t.timestamps
    end
    add_index :ledger_withdrawal_request_bills,
      [:ledger_withdrawal_request_id, :qbo_account_id, :qbo_bill_id],
      unique: true, name: "idx_lwrb_unique_per_bill"
    add_index :ledger_withdrawal_request_bills,
      [:qbo_account_id, :qbo_bill_id],
      name: "idx_lwrb_on_bill"
  end
end
