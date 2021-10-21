class AdminUserRacialBackground < ApplicationRecord
  belongs_to :racial_background
  belongs_to :admin_user
end
