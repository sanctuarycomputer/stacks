class ConstrainContributorPayoutAmountToTwoDecimals < ActiveRecord::Migration[6.1]
  def up
    # Round existing values before tightening the column so the cast doesn't
    # error on rows that happen to exceed the new precision. ROUND() with 2
    # digits is the same rounding the new column type will apply on future
    # writes, so this is a no-op where values are already clean.
    execute <<~SQL.squish
      UPDATE contributor_payouts
      SET amount = ROUND(amount::numeric, 2)
      WHERE amount IS NOT NULL
    SQL

    change_column :contributor_payouts, :amount, :decimal,
      precision: 10, scale: 2, default: 0.0, null: false
  end

  def down
    change_column :contributor_payouts, :amount, :decimal,
      default: 0.0, null: false
  end
end
