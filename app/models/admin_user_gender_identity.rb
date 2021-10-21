class AdminUserGenderIdentity < ApplicationRecord
  belongs_to :gender_identity
  belongs_to :admin_user
end
