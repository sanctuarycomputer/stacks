class QboVendor < ApplicationRecord
  self.primary_key = "qbo_id"

  def display_name
    data.dig("display_name")
  end
end
