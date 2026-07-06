class AddReviewersLastNotifiedAtToInvoiceTrackers < ActiveRecord::Migration[6.1]
  def change
    add_column :invoice_trackers, :reviewers_last_notified_at, :datetime
  end
end
