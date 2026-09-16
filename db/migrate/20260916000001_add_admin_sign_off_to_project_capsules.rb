class AddAdminSignOffToProjectCapsules < ActiveRecord::Migration[6.1]
  def up
    add_column :project_capsules, :admin_signed_off_at, :datetime
    add_reference :project_capsules, :admin_signed_off_by,
      foreign_key: { to_table: :admin_users }, null: true
    add_column :project_capsules, :admin_signed_off_selections, :string,
      array: true, null: false, default: []
    add_column :project_capsules, :sign_off_exempt, :boolean,
      null: false, default: false

    # Grandfather capsules whose close-out decisions are already made — the exact
    # set that would otherwise flip from Complete back to Pending. Capsules with
    # statuses still blank are already Pending, so gating them reopens nothing.
    # Raw SQL, not the model, so this can't break if ProjectCapsule's callbacks
    # change later.
    execute <<~SQL
      UPDATE project_capsules SET sign_off_exempt = true
      WHERE client_feedback_survey_status       IS NOT NULL
        AND internal_marketing_status           IS NOT NULL
        AND capsule_status                      IS NOT NULL
        AND project_satisfaction_survey_status  IS NOT NULL;
    SQL
  end

  def down
    remove_column :project_capsules, :sign_off_exempt
    remove_column :project_capsules, :admin_signed_off_selections
    remove_reference :project_capsules, :admin_signed_off_by
    remove_column :project_capsules, :admin_signed_off_at
  end
end
