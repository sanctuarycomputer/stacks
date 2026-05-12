class FoldMiscPaymentsIntoAdjustments < ActiveRecord::Migration[6.1]
  def up
    say_with_time "Folding misc_payments into contributor_adjustments" do
      sanctuary_id = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME).id
      count = 0

      rows = connection.exec_query("SELECT id, amount, remittance, paid_at, contributor_id, created_at, updated_at, deleted_at FROM misc_payments")
      rows.each do |r|
        contributor_id = r["contributor_id"]
        next if contributor_id.nil?

        # Find or create Sanctuary ledger for this contributor
        ledger_row = connection.exec_query(
          "SELECT id FROM ledgers WHERE enterprise_id = #{sanctuary_id} AND contributor_id = #{contributor_id}"
        ).first

        ledger_id =
          if ledger_row
            ledger_row["id"].to_i
          else
            connection.exec_query(
              "INSERT INTO ledgers (enterprise_id, contributor_id, created_at, updated_at) " \
              "VALUES (#{sanctuary_id}, #{contributor_id}, NOW(), NOW()) RETURNING id"
            ).first["id"].to_i
          end

        # MP deducted from balance — CA with negative amount achieves the same.
        new_amount = -r["amount"].to_d

        description = "Misc payment: " + ((r["remittance"].to_s.strip.presence) || "no remittance")
        # Escape single quotes for SQL safety
        safe_description = description.gsub("'", "''")

        # Insert ContributorAdjustment
        deleted_at_sql = r["deleted_at"].present? ? "'#{r["deleted_at"]}'" : "NULL"
        connection.exec_query(<<~SQL)
          INSERT INTO contributor_adjustments
            (ledger_id, amount, effective_on, description, created_at, updated_at, deleted_at)
          VALUES
            (#{ledger_id},
             #{new_amount.to_s("F")},
             '#{r["paid_at"]}',
             '#{safe_description}',
             '#{r["created_at"]}',
             '#{r["updated_at"]}',
             #{deleted_at_sql})
        SQL
        count += 1
      end
      count
    end

    # Keep the misc_payments table dormant rather than dropping it, so the
    # original rows remain recoverable if the fold ever needs to be reviewed.
    # The MiscPayment model and admin page are gone; no app code reads it.
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Restore from DB backup to revert"
  end
end
