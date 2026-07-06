class RouteDeelInvoiceAdjustmentsThroughLedgerAndDropLedgerWithdrawals < ActiveRecord::Migration[6.1]
  def up
    sanctuary = Enterprise.find_or_create_by!(name: Enterprise::SANCTUARY_NAME)

    # Step 1: Add ledger_id (nullable) to deel_invoice_adjustments
    add_reference :deel_invoice_adjustments, :ledger, null: true, foreign_key: true

    # Step 2: Backfill ledger_id (one Sanctuary ledger per contributor)
    say_with_time "Backfilling ledger_id on deel_invoice_adjustments" do
      count = 0
      ledger_id_by_contributor = {}
      rows = connection.exec_query("SELECT id, contributor_id FROM deel_invoice_adjustments")
      rows.each do |r|
        contributor_id = r["contributor_id"]
        next if contributor_id.nil?

        ledger_id = ledger_id_by_contributor[contributor_id] ||= begin
          existing = connection.exec_query(
            "SELECT id FROM ledgers WHERE enterprise_id = #{sanctuary.id} AND contributor_id = #{contributor_id}"
          ).first
          if existing
            existing["id"].to_i
          else
            connection.exec_query(
              "INSERT INTO ledgers (enterprise_id, contributor_id, created_at, updated_at) " \
              "VALUES (#{sanctuary.id}, #{contributor_id}, NOW(), NOW()) RETURNING id"
            ).first["id"].to_i
          end
        end

        connection.exec_query("UPDATE deel_invoice_adjustments SET ledger_id = #{ledger_id} WHERE id = #{r["id"]}")
        count += 1
      end
      count
    end

    # Step 3: NOT NULL constraint
    change_column_null :deel_invoice_adjustments, :ledger_id, false

    # Step 4: Drop contributor_id
    remove_index :deel_invoice_adjustments, :contributor_id if index_exists?(:deel_invoice_adjustments, :contributor_id)
    remove_column :deel_invoice_adjustments, :contributor_id

    # Step 5: Drop ledger_withdrawals entirely (LedgerWithdrawal was duplicative of DeelInvoiceAdjustment)
    drop_table :ledger_withdrawals
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Restore from DB backup to revert"
  end
end
