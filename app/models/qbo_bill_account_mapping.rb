# One routing rule for the QBO bill account mapping engine: for a given
# enterprise + line-item kind, which QBO chart account should the bill
# line post to. Subject columns scope the rule:
#   - project_tracker_id set  → project-tracker-level override (wins first)
#   - contributor_id set      → contributor-level override (wins second)
#   - both NULL               → entity-level default (fallback)
# Resolution happens in Qbo::BillAccountResolver. See the design doc at
# docs/superpowers/specs/2026-06-10-qbo-bill-account-mapping-engine-design.md
class QboBillAccountMapping < ApplicationRecord
  LINE_ITEM_KEYS = %w[
    payout_individual_contributor
    payout_account_lead_base
    payout_account_lead_surplus
    payout_project_lead_base
    payout_project_lead_surplus
    payout_commission
    trueup
    contributor_adjustment
    profit_share
    pay_stub
  ].freeze

  belongs_to :enterprise
  belongs_to :project_tracker, optional: true
  belongs_to :contributor, optional: true

  validates :line_item_key, presence: true, inclusion: { in: LINE_ITEM_KEYS }
  validates :line_item_key, uniqueness: { scope: [:enterprise_id, :project_tracker_id, :contributor_id] }
  validates :qbo_chart_account_qbo_id, presence: true
  validate :at_most_one_subject
  validate :chart_account_exists_and_active

  def subject_label
    return "Project: #{project_tracker.name}" if project_tracker.present?
    return "Contributor: #{contributor.display_name}" if contributor.present?
    "Entity default"
  end

  # The mirrored chart-of-accounts row this mapping points at, scoped to
  # the enterprise's realm. Composite (qbo_account_id, qbo_id) lookup,
  # same style as SyncsAsQboBill#qbo_bill.
  def chart_account
    qa = enterprise&.qbo_account
    return nil if qa.nil?
    QboChartAccount.find_by(qbo_account_id: qa.id, qbo_id: qbo_chart_account_qbo_id)
  end

  private

  def at_most_one_subject
    if project_tracker_id.present? && contributor_id.present?
      errors.add(:base, "Set a project tracker OR a contributor, not both. Leave both blank for the entity-level default.")
    end
  end

  def chart_account_exists_and_active
    return if qbo_chart_account_qbo_id.blank? || enterprise.nil?

    qa = enterprise.qbo_account
    if qa.nil?
      errors.add(:enterprise, "has no connected QBO account")
      return
    end

    ca = QboChartAccount.find_by(qbo_account_id: qa.id, qbo_id: qbo_chart_account_qbo_id)
    if ca.nil?
      errors.add(:qbo_chart_account_qbo_id, "not found in this enterprise's chart of accounts mirror (try Refresh Chart of Accounts)")
    elsif !ca.active?
      errors.add(:qbo_chart_account_qbo_id, "is inactive in QBO")
    end
  end
end
