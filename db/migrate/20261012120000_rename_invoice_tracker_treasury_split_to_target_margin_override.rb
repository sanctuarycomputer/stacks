class RenameInvoiceTrackerTreasurySplitToTargetMarginOverride < ActiveRecord::Migration[6.1]
  def up
    remove_check_constraint :invoice_trackers, name: "check_company_treasury_split_range"
    rename_column :invoice_trackers, :company_treasury_split, :target_margin_override
    change_column_default :invoice_trackers, :target_margin_override, from: 0.3, to: nil
    add_check_constraint :invoice_trackers,
      "target_margin_override >= 0 AND target_margin_override <= 1",
      name: "check_target_margin_override_range"

    # Trackers that already have payouts keep 0.3 as an explicit override:
    # ProjectTracker#billing_model is live, not a per-invoice snapshot, so
    # nulling them would re-cap invoices already paid out at 70%.
    execute <<~SQL
      UPDATE invoice_trackers
      SET target_margin_override = NULL
      WHERE target_margin_override = 0.3
        AND NOT EXISTS (
          SELECT 1 FROM contributor_payouts cp
          WHERE cp.invoice_tracker_id = invoice_trackers.id
            AND cp.deleted_at IS NULL
        )
    SQL
  end

  def down
    execute "UPDATE invoice_trackers SET target_margin_override = 0.3 WHERE target_margin_override IS NULL"
    remove_check_constraint :invoice_trackers, name: "check_target_margin_override_range"
    change_column_default :invoice_trackers, :target_margin_override, from: nil, to: 0.3
    rename_column :invoice_trackers, :target_margin_override, :company_treasury_split
    add_check_constraint :invoice_trackers,
      "company_treasury_split >= 0 AND company_treasury_split <= 1",
      name: "check_company_treasury_split_range"
  end
end
