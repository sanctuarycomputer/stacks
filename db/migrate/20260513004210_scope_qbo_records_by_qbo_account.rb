class ScopeQboRecordsByQboAccount < ActiveRecord::Migration[6.1]
  # Scopes existing QBO records (qbo_bills, qbo_vendors, qbo_invoices) by
  # qbo_account_id. Before this migration, all QBO records were implicitly
  # "Sanctuary's" because Stacks::Quickbooks read credentials from a single
  # global config; after this, every record is explicitly owned by a QboAccount
  # so non-Sanctuary enterprises (Garden3D, Index, USB Club) can sync to their
  # own QBO companies.
  #
  # The migration also creates Sanctuary's QboAccount (if absent) from the
  # legacy global config, and migrates the existing QuickbooksToken row into
  # Sanctuary's QboToken so the per-account token store has the live credentials.
  def up
    cfg = Stacks::Utils.config[:quickbooks]
    raise "Missing :quickbooks config — cannot bootstrap Sanctuary's QboAccount" if cfg.blank?

    sanctuary = Enterprise.find_by!(name: Enterprise::SANCTUARY_NAME)

    # Locate or create Sanctuary's QboAccount. Prefer one already linked to
    # the Sanctuary enterprise; otherwise look for one matching the legacy
    # global realm_id (the realm all existing QBO records actually came from);
    # otherwise create a new one from the global config.
    qa = sanctuary.qbo_account
    qa ||= QboAccount.find_by(realm_id: cfg[:realm_id])
    if qa
      qa.update!(enterprise: sanctuary) if qa.enterprise_id != sanctuary.id
    else
      qa = QboAccount.create!(
        enterprise: sanctuary,
        client_id: cfg[:client_id],
        client_secret: cfg[:client_secret],
        realm_id: cfg[:realm_id],
      )
    end

    # Migrate the singleton QuickbooksToken row into a QboToken on Sanctuary's
    # account. QboToken is the per-account store; QuickbooksToken is the legacy
    # global store. Both will hold the same data after this migration; once the
    # Stacks::Quickbooks refactor (a follow-up commit in this series) routes its
    # reads/writes through Sanctuary's QboToken, QuickbooksToken becomes dead
    # storage and can be dropped in a later cleanup.
    legacy = QuickbooksToken.order(:created_at).last
    if legacy && qa.qbo_token.nil?
      QboToken.create!(
        qbo_account: qa,
        token: legacy.token,
        refresh_token: legacy.refresh_token,
      )
    end

    sid = qa.id

    %i[qbo_bills qbo_vendors qbo_invoices].each do |table|
      add_reference table, :qbo_account, null: true, foreign_key: true
      execute "UPDATE #{table} SET qbo_account_id = #{sid}"
      change_column_null table, :qbo_account_id, false
    end

    # The composite-unique swap below requires dropping foreign keys that
    # reference qbo_bills.qbo_id (Postgres won't let you drop a referenced
    # unique index). qbo_id is no longer globally unique after this migration,
    # so the legacy single-column FKs aren't sound anyway — the upcoming
    # SyncsAsQboBill refactor enforces proper composite (qbo_account_id, qbo_id)
    # lookup at the application layer.
    %i[contributor_payouts trueups].each do |table|
      remove_foreign_key table, :qbo_bills if foreign_key_exists?(table, :qbo_bills)
    end

    # qbo_bills: replace global unique on qbo_id with composite unique
    if index_exists?(:qbo_bills, :qbo_id, name: "index_qbo_bills_on_qbo_id")
      remove_index :qbo_bills, name: "index_qbo_bills_on_qbo_id"
    end
    add_index :qbo_bills, [:qbo_account_id, :qbo_id], unique: true,
      name: "index_qbo_bills_on_qbo_account_and_qbo_id"
    # Plain non-unique index on qbo_id so the host-side lookups (still keyed
    # on qbo_bill_id string) remain reasonably fast even before the upcoming
    # SyncsAsQboBill refactor switches to composite-scoped finds.
    add_index :qbo_bills, :qbo_id, name: "index_qbo_bills_on_qbo_id"

    # qbo_vendors: same
    if index_exists?(:qbo_vendors, :qbo_id, name: "index_qbo_vendors_on_qbo_id")
      remove_index :qbo_vendors, name: "index_qbo_vendors_on_qbo_id"
    end
    add_index :qbo_vendors, [:qbo_account_id, :qbo_id], unique: true,
      name: "index_qbo_vendors_on_qbo_account_and_qbo_id"

    # qbo_invoices: same — preserve the existing partial-where semantics
    if index_exists?(:qbo_invoices, :qbo_id, name: "index_qbo_invoices_on_qbo_id")
      remove_index :qbo_invoices, name: "index_qbo_invoices_on_qbo_id"
    end
    add_index :qbo_invoices, [:qbo_account_id, :qbo_id], unique: true,
      where: "qbo_id IS NOT NULL",
      name: "index_qbo_invoices_on_qbo_account_and_qbo_id"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "Restore from DB backup to revert"
  end
end
