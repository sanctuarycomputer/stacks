class AdminUserAcknowledgement < ApplicationRecord
  belongs_to :acknowledgement
  belongs_to :admin_user
end
