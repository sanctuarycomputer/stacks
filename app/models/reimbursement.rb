class Reimbursement < ApplicationRecord
  acts_as_paranoid
  include LedgerItem
  include BustsTaskCache

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
    "/admin/contributors/#{contributor.id}/reimbursements/#{id}"
  end

  def display_name
    "#{contributor.forecast_person.email} - #{created_at.strftime("%B %d, %Y")}: #{description}"
  end

  def accepted?
    accepted_by.present?
  end

  def payable?
    accepted?
  end

  def effective_on_for_display
    created_at.to_date
  end
end
