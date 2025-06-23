class AddAllowEarlyContributorPayoutsOnToContributorPayouts < ActiveRecord::Migration[6.1]
  def change
    add_column :invoice_trackers, :allow_early_contributor_payouts_on, :date
  end
end
