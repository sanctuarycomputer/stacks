# An explicit, admin-granted permission for an AdminUser. A grant with no
# subject is global (e.g. a lead-in-training who should see everything a
# real lead sees); a grant with a subject narrows the permission to that
# record. Extend PERMISSIONS / SUBJECT_TYPES to add new kinds — the shape
# needs no schema change.
class PermissionGrant < ApplicationRecord
  PERMISSIONS = %w[lead].freeze
  SUBJECT_TYPES = %w[ProjectTracker].freeze

  belongs_to :admin_user
  belongs_to :granted_by, class_name: "AdminUser", optional: true
  belongs_to :subject, polymorphic: true, optional: true

  before_validation do
    self.subject_type = "ProjectTracker" if subject_id.present? && subject_type.blank?
    self.subject_type = nil if subject_id.blank?
  end

  validates :permission, inclusion: { in: PERMISSIONS }
  validates :subject_type, inclusion: { in: SUBJECT_TYPES }, allow_nil: true
  validates :permission, uniqueness: { scope: [:admin_user_id, :subject_type, :subject_id] }

  scope :global, -> { where(subject_type: nil, subject_id: nil) }
  scope :for_permission, ->(p) { where(permission: p) }

  def global?
    subject_type.nil? && subject_id.nil?
  end
end
