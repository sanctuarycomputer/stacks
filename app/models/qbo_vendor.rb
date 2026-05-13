class QboVendor < ApplicationRecord
  self.primary_key = "qbo_id"
  belongs_to :qbo_account

  def display_name
    data.dig("display_name")
  end
end
