class CreateRecurringLedgerAdjustments < ActiveRecord::Migration[6.1]
  def change
    create_table :recurring_ledger_adjustments do |t|
      t.references :ledger, null: false, foreign_key: true
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.text :description, null: false, default: ""
      # Cadence is per-row (monthly / twice_monthly / quarterly) so the same
      # cron can advance any row regardless of the enterprise's own pay cycle
      # cadence.
      t.string :cadence, null: false
      # Next date a ContributorAdjustment should be materialized from this
      # row. The cron picks up rows where next_due_on <= today, creates the
      # adjustment with effective_on = next_due_on, then advances this column
      # by the cadence.
      t.date :next_due_on, null: false
      t.date :last_materialized_on
      t.datetime :paused_at
      t.timestamps
    end

    add_index :recurring_ledger_adjustments, :next_due_on
    add_index :recurring_ledger_adjustments, :paused_at
  end
end
