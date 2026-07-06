class UpdateAssociatesAwardAgreementToV2 < ActiveRecord::Migration[6.1]
  def change
    add_column :associates_award_agreements, :total_awardable_units, :integer, default: 5_000_000

    remove_column :associates_award_agreements, :initial_unit_grant
    remove_column :associates_award_agreements, :vesting_unit_increments
    remove_column :associates_award_agreements, :vesting_periods
    remove_column :associates_award_agreements, :vesting_period_type
  end
end