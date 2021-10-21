class AdminUserCommunity < ApplicationRecord
  belongs_to :community
  belongs_to :admin_user
end
