class RouteLedgerModelsThroughLedger < ActiveRecord::Migration[6.1]
  TABLES = %w[contributor_payouts contributor_adjustments trueups reimbursements profit_shares].freeze

  def up
    sanctuary = Enterprise.find_or_create_by!(name: Enterprise::SANCTUARY_NAME)

    # Step 1: Add nullable ledger_id to each table
    TABLES.each do |t|
      add_reference t.to_sym, :ledger, null: true, foreign_key: true
    end

    # Step 2: Backfill ledger_id for each existing row, creating one Sanctuary
    # ledger per contributor on the fly.
    ledger_id_by_contributor = {}
    TABLES.each do |table|
      say_with_time "Backfilling ledger_id on #{table}" do
        count = 0
        rows = connection.exec_query("SELECT id, contributor_id FROM #{table}")
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

          connection.exec_query(
            "UPDATE #{table} SET ledger_id = #{ledger_id} WHERE id = #{r["id"]}"
          )
          count += 1
        end
        count
      end
    end

    # Step 3: Make ledger_id NOT NULL
    TABLES.each do |t|
      change_column_null t.to_sym, :ledger_id, false
    end

    # Step 4: Drop contributor_id (model-level associations are updated in the
    # same commit so the schema change is consistent with the code).
    # profit_shares has a composite unique index on (periodic_report_id, contributor_id) —
    # remove it and re-add the equivalent on (periodic_report_id, ledger_id).
    if index_exists?(:profit_shares, [:periodic_report_id, :contributor_id])
      remove_index :profit_shares, [:periodic_report_id, :contributor_id]
    end

    TABLES.each do |t|
      remove_index t.to_sym, :contributor_id if index_exists?(t.to_sym, :contributor_id)
      remove_column t.to_sym, :contributor_id
    end

    add_index :profit_shares, [:periodic_report_id, :ledger_id], unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Restore from DB backup to revert"
  end
end
