class AdminUserInterest < ApplicationRecord
  belongs_to :interest
  belongs_to :admin_user
end
