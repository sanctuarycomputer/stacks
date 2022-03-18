class StudioMembership < ApplicationRecord
  belongs_to :studio
  belongs_to :admin_user
end
