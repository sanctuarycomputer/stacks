class QualificationGrant < ApplicationRecord
  belongs_to :admin_user
  belongs_to :qualification
  belongs_to :granted_by, class_name: "AdminUser", optional: true

  validates :granted_at, presence: true
  validates :qualification_id, uniqueness: { scope: :admin_user_id, message: "is already held by this person" }
end
