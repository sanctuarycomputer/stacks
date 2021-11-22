class PreProfitSharePurchase < ApplicationRecord
  belongs_to :admin_user
  validates :amount, presence: :true
  validates :purchased_at, presence: :true
end
