class QboVendor < ApplicationRecord
  # No `self.primary_key = "qbo_id"` override: callers that need the QBO
  # entity ID use `.qbo_id` explicitly, and downstream associations
  # (Contributor, QboBill) declare their own `primary_key: "qbo_id"` on
  # the belongs_to. Keeping the default `id` primary key lets
  # ContributorQboVendor join cleanly via a real bigint FK.
  belongs_to :qbo_account

  def display_name
    data.dig("display_name")
  end
end
