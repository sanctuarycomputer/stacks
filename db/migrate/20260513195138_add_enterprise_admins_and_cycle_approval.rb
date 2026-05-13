class AddEnterpriseAdminsAndCycleApproval < ActiveRecord::Migration[6.1]
  def change
    # enterprise_admins join table: which AdminUsers can approve cycles and
    # otherwise act as scoped admins for a given Enterprise. Global is_admin?
    # remains a super-admin role that bypasses this scope.
    create_table :enterprise_admins do |t|
      t.references :enterprise, null: false, foreign_key: true
      t.references :admin_user, null: false, foreign_key: true
      t.timestamps
    end
    add_index :enterprise_admins, [:enterprise_id, :admin_user_id], unique: true,
      name: "index_enterprise_admins_unique"

    # PayCycle gains an approval pair, distinct from per-stub acceptance.
    # Once approved AND all individual stubs are accepted, stubs become payable.
    add_column :pay_cycles, :approved_at, :datetime
    add_reference :pay_cycles, :approved_by, foreign_key: { to_table: :admin_users }
  end
end
