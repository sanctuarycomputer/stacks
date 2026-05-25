# Adds a direct qbo_account_id column to invoice_trackers,
# contributor_adjustments, and adhoc_invoice_trackers. Uses a trigger instead
# of PG 15's column-list ON DELETE SET NULL syntax for compatibility with
# older PG versions (Heroku CI uses in-dyno PG which may be < 15).
class AddQboAccountIdToTrackersAndAdjustments < ActiveRecord::Migration[6.1]
  def up
    sanctuary_qa_id = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME).qbo_account.id

    # Postgres FK targets need a non-partial UNIQUE constraint, not just a
    # unique partial index. qbo_id is NOT NULL on qbo_invoices, so this is a
    # no-op uniqueness-wise — only the constraint type differs.
    execute <<~SQL
      ALTER TABLE qbo_invoices
        ADD CONSTRAINT qbo_invoices_qbo_account_id_qbo_id_key
        UNIQUE (qbo_account_id, qbo_id)
    SQL

    # Normalize: 8 ContributorAdjustment rows store '' instead of NULL — clean
    # so the FK accepts NULL semantics.
    execute "UPDATE contributor_adjustments SET qbo_invoice_id = NULL WHERE qbo_invoice_id = ''"

    add_qbo_account_to_invoice_trackers(sanctuary_qa_id)
    add_qbo_account_to_contributor_adjustments(sanctuary_qa_id)
    add_qbo_account_to_adhoc_invoice_trackers(sanctuary_qa_id)

    # Trigger replaces PG 15's ON DELETE SET NULL (column_list). When a
    # qbo_invoice is deleted, null out qbo_invoice_id on child rows while
    # preserving the NOT NULL qbo_account_id.
    execute <<~SQL
      CREATE OR REPLACE FUNCTION nullify_qbo_invoice_id_on_children()
      RETURNS trigger AS $$
      BEGIN
        UPDATE invoice_trackers SET qbo_invoice_id = NULL
          WHERE qbo_account_id = OLD.qbo_account_id AND qbo_invoice_id = OLD.qbo_id;
        UPDATE contributor_adjustments SET qbo_invoice_id = NULL
          WHERE qbo_account_id = OLD.qbo_account_id AND qbo_invoice_id = OLD.qbo_id;
        UPDATE adhoc_invoice_trackers SET qbo_invoice_id = NULL
          WHERE qbo_account_id = OLD.qbo_account_id AND qbo_invoice_id = OLD.qbo_id;
        RETURN OLD;
      END;
      $$ LANGUAGE plpgsql;

      CREATE TRIGGER trg_qbo_invoices_nullify_children
        BEFORE DELETE ON qbo_invoices
        FOR EACH ROW
        EXECUTE FUNCTION nullify_qbo_invoice_id_on_children();
    SQL
  end

  def down
    execute "DROP TRIGGER IF EXISTS trg_qbo_invoices_nullify_children ON qbo_invoices"
    execute "DROP FUNCTION IF EXISTS nullify_qbo_invoice_id_on_children()"
    [:adhoc_invoice_trackers, :contributor_adjustments, :invoice_trackers].each do |t|
      execute "ALTER TABLE #{t} DROP CONSTRAINT IF EXISTS fk_#{t}_qbo_invoice"
      remove_index t, name: "index_#{t}_on_qa_and_qbo_invoice" if index_exists?(t, [:qbo_account_id, :qbo_invoice_id], name: "index_#{t}_on_qa_and_qbo_invoice")
      remove_reference t, :qbo_account, foreign_key: true
    end
    execute "ALTER TABLE qbo_invoices DROP CONSTRAINT IF EXISTS qbo_invoices_qbo_account_id_qbo_id_key"
  end

  private

  def backfill_passes(table, default_pass_sql)
    # Pass 1: derive qa from the QboInvoice row that actually has this qbo_id,
    # regardless of which enterprise the row's forecast_client/ledger maps to.
    # Catches every cross-realm legacy attachment automatically — no hardcoded
    # list needed. Composite FK can't be added with mismatched qa, so this
    # pass has to run before the default fallback.
    execute <<~SQL
      UPDATE #{table} AS t
      SET qbo_account_id = qi.qbo_account_id
      FROM qbo_invoices AS qi
      WHERE t.qbo_invoice_id = qi.qbo_id
        AND t.qbo_account_id IS NULL
    SQL

    # Pass 2: rows still without a qa get the table-specific default
    # (caller-supplied SQL).
    execute default_pass_sql

    # Pass 3: any remaining row whose (qbo_account_id, qbo_invoice_id) doesn't
    # reference a real QboInvoice — null out the qbo_invoice_id so the FK can
    # be added. These are dangling FKs the old qbo_id-only belongs_to silently
    # masked.
    execute <<~SQL
      UPDATE #{table} AS t
      SET qbo_invoice_id = NULL
      WHERE t.qbo_invoice_id IS NOT NULL
        AND NOT EXISTS (
          SELECT 1 FROM qbo_invoices qi
          WHERE qi.qbo_account_id = t.qbo_account_id AND qi.qbo_id = t.qbo_invoice_id
        )
    SQL
  end

  def install_composite_fk(table)
    change_column_null table, :qbo_account_id, false

    # Composite FK without ON DELETE CASCADE/SET NULL — deletions are handled
    # by a BEFORE DELETE trigger on qbo_invoices that nulls qbo_invoice_id on
    # child rows (preserving the NOT NULL qbo_account_id).
    execute <<~SQL
      ALTER TABLE #{table}
        ADD CONSTRAINT fk_#{table}_qbo_invoice
        FOREIGN KEY (qbo_account_id, qbo_invoice_id)
        REFERENCES qbo_invoices (qbo_account_id, qbo_id)
        DEFERRABLE INITIALLY DEFERRED
    SQL
    add_index table, [:qbo_account_id, :qbo_invoice_id], name: "index_#{table}_on_qa_and_qbo_invoice"
  end

  def add_qbo_account_to_invoice_trackers(sanctuary_qa_id)
    add_reference :invoice_trackers, :qbo_account, foreign_key: true, null: true

    # Default for invoice_trackers: forecast_client → enterprise_forecast_client
    # → enterprise → qbo_account. External (unmapped) clients fall through to
    # Sanctuary's qa.
    default_pass = <<~SQL
      UPDATE invoice_trackers AS t
      SET qbo_account_id = COALESCE(qa.id, #{sanctuary_qa_id})
      FROM forecast_clients fc
      LEFT JOIN enterprise_forecast_clients efc ON efc.forecast_client_id = fc.forecast_id
      LEFT JOIN qbo_accounts qa ON qa.enterprise_id = efc.enterprise_id
      WHERE t.qbo_account_id IS NULL
        AND t.forecast_client_id = fc.forecast_id
    SQL
    backfill_passes(:invoice_trackers, default_pass)
    install_composite_fk(:invoice_trackers)
  end

  def add_qbo_account_to_contributor_adjustments(sanctuary_qa_id)
    add_reference :contributor_adjustments, :qbo_account, foreign_key: true, null: true

    # Default for contributor_adjustments: ledger → enterprise → qbo_account.
    default_pass = <<~SQL
      UPDATE contributor_adjustments AS t
      SET qbo_account_id = COALESCE(qa.id, #{sanctuary_qa_id})
      FROM ledgers l
      LEFT JOIN qbo_accounts qa ON qa.enterprise_id = l.enterprise_id
      WHERE t.qbo_account_id IS NULL
        AND t.ledger_id = l.id
    SQL
    backfill_passes(:contributor_adjustments, default_pass)
    install_composite_fk(:contributor_adjustments)
  end

  def add_qbo_account_to_adhoc_invoice_trackers(sanctuary_qa_id)
    add_reference :adhoc_invoice_trackers, :qbo_account, foreign_key: true, null: true

    # Default for adhoc_invoice_trackers: Sanctuary (historical assumption).
    default_pass = <<~SQL
      UPDATE adhoc_invoice_trackers AS t
      SET qbo_account_id = #{sanctuary_qa_id}
      WHERE t.qbo_account_id IS NULL
    SQL
    backfill_passes(:adhoc_invoice_trackers, default_pass)
    install_composite_fk(:adhoc_invoice_trackers)
  end
end
