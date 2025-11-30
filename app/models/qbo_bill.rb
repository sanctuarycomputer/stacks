class QboBill < ApplicationRecord
  self.primary_key = "qbo_id"
  belongs_to :qbo_vendor, class_name: "QboVendor", foreign_key: "qbo_vendor_id", primary_key: "qbo_id"
end
