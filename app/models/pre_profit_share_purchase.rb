class PreProfitSharePurchase < ApplicationRecord
  scope :this_year, -> {
    where(purchased_at: Time.now.beginning_of_year..Time.now.end_of_year)
  }

  belongs_to :admin_user
  validates :amount, presence: :true
  validates :purchased_at, presence: :true
end
