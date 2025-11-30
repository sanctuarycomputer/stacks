class MoveLedgerItemsToContributors < ActiveRecord::Migration[6.1]
  def change
    add_reference :contributor_payouts, :contributor, null: true, foreign_key: true
    add_reference :misc_payments, :contributor, null: true, foreign_key: true
    add_reference :trueups, :contributor, null: true, foreign_key: true

    ContributorPayout.with_deleted.all.each do |cp|
      cp.contributor = cp.forecast_person.contributor
      deleted = cp.deleted?
      cp.recover if deleted
      cp.save!(validate: false)
      cp.destroy if deleted
    end

    MiscPayment.with_deleted.all.each do |mp|
      mp.contributor = mp.forecast_person.contributor
      deleted = mp.deleted?
      mp.recover if deleted
      mp.save!(validate: false)
      mp.destroy if deleted
    end

    Trueup.with_deleted.all.each do |t|
      t.contributor = t.forecast_person.contributor
      deleted = t.deleted?
      t.recover if deleted
      t.save!(validate: false)
      t.destroy if deleted
    end

    remove_column :contributor_payouts, :forecast_person_id
    remove_column :misc_payments, :forecast_person_id
    remove_column :trueups, :forecast_person_id

    change_column_null :contributor_payouts, :contributor_id, false
    change_column_null :misc_payments, :contributor_id, false
    change_column_null :trueups, :contributor_id, false
  end
end
