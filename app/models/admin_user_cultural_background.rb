class AdminUserCulturalBackground < ApplicationRecord
  belongs_to :cultural_background
  belongs_to :admin_user
end
