class Enterprise < ApplicationRecord
  has_one :qbo_account
  accepts_nested_attributes_for :qbo_account, allow_destroy: true
end
