class PayCycle < ApplicationRecord
  acts_as_paranoid

  belongs_to :enterprise
  belongs_to :created_by, class_name: "AdminUser", optional: true
  has_many :pay_stubs, dependent: :destroy

  validates :starts_at, :ends_at, presence: true
  validates :enterprise_id, uniqueness: { scope: [:starts_at, :ends_at] }
  validate :ends_at_on_or_after_starts_at

  # Computed status across this cycle's stubs.
  #   :no_stubs       → no stubs have been generated yet
  #   :some_pending   → at least one stub is unaccepted
  #   :all_accepted   → every stub is accepted (implicit lock)
  def stubs_status
    return :no_stubs unless pay_stubs.exists?
    pay_stubs.where(accepted_at: nil).none? ? :all_accepted : :some_pending
  end

  private

  def ends_at_on_or_after_starts_at
    return if starts_at.blank? || ends_at.blank?
    errors.add(:ends_at, "must be on or after starts_at") if ends_at < starts_at
  end
end
