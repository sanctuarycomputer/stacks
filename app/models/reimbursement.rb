class Reimbursement < ApplicationRecord
  acts_as_paranoid
  belongs_to :contributor
  belongs_to :accepted_by, class_name: 'AdminUser', optional: true

  scope :accepted, -> {
    where.not(accepted_by: nil)
  }

  scope :pending, -> {
    where.not(id: accepted)
  }

  def name
    display_name
  end

  def external_link
    "/admin/contributors/#{contributor_id}/reimbursements/#{id}"
  end

  def display_name
    "#{contributor.forecast_person.email} - #{created_at.strftime("%B %d, %Y")}: #{description}"
  end

  def accepted?
    accepted_by.present?
  end
end
