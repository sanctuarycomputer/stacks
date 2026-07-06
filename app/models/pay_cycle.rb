class PayCycle < ApplicationRecord
  acts_as_paranoid

  belongs_to :enterprise
  belongs_to :created_by, class_name: "AdminUser", optional: true
  belongs_to :approved_by, class_name: "AdminUser", optional: true
  has_many :pay_stubs, dependent: :destroy

  validates :starts_at, :ends_at, presence: true
  validates :enterprise_id, uniqueness: { scope: [:starts_at, :ends_at] }
  validate :ends_at_on_or_after_starts_at
  validate :no_date_overlap_with_siblings
  validate :starts_immediately_after_latest_sibling

  before_destroy :reject_destroy_when_any_stub_is_payable_or_paid

  class CycleHasPayableStubsError < StandardError; end
  class NotAuthorizedToApprove < StandardError; end

  # Computed status across this cycle's stubs.
  #   :no_stubs       → no stubs have been generated yet
  #   :some_pending   → at least one stub is unaccepted
  #   :all_accepted   → every stub is accepted (implicit lock)
  def stubs_status
    return :no_stubs unless pay_stubs.exists?
    pay_stubs.where(accepted_at: nil).none? ? :all_accepted : :some_pending
  end

  def approved?
    approved_at.present?
  end

  # Mirror of InvoiceTracker#changes_in_forecast — computes what
  # PayCycles::GenerateStubs would produce against current Forecast state and
  # diffs it against the stored pay stubs. Returns an Array of `[op, email, ...]`
  # entries the view renders inline:
  #   ["~", email, was_amount, now_amount]  → contributor's total changed
  #   ["-", email, "no qualifying hours anymore"]  → contributor would be soft-deleted
  #   ["+", email, "newly qualifies for hours"]    → contributor would be added
  # Empty array means stored stubs are in sync with Forecast (or there are no
  # stubs yet — we don't try to diff against a non-existent baseline).
  def changes_in_forecast
    return [] if pay_stubs.empty?

    current_by_fp = PayCycles::GenerateStubs.new(self).compute_per_contributor_lines
    stored_by_fp = pay_stubs.includes(ledger: { contributor: :forecast_person }).each_with_object({}) do |stub, h|
      h[stub.contributor.forecast_person] = stub
    end

    changes = []

    stored_by_fp.each do |fp, stub|
      lines = current_by_fp[fp]
      if lines.nil?
        changes << ["-", fp.email, "no longer has qualifying hours in Forecast"]
        next
      end
      now_amount = lines.sum { |l| l["amount"].to_f }.round(2)
      was_amount = stub.amount.to_f.round(2)
      changes << ["~", fp.email, was_amount, now_amount] if (now_amount - was_amount).abs >= 0.01
    end

    current_by_fp.each_key do |fp|
      next if stored_by_fp.key?(fp)
      changes << ["+", fp.email, "newly qualifies for hours — stub would be created"]
    end

    changes
  end

  # Enterprise-admin (or global super-admin) approves the cycle. Distinct from
  # per-stub acceptance: cycle approval gates whether ANY stub in the cycle
  # becomes payable, on top of every individual stub being accepted. Until the
  # cycle is approved AND every stub accepted, no stub is payable.
  def toggle_approval!(by:)
    raise NotAuthorizedToApprove, "AdminUser #{by&.email.inspect} cannot approve cycles for #{enterprise.name}" unless by&.admin_of?(enterprise)

    if approved?
      update!(approved_at: nil, approved_by_id: nil)
    else
      update!(approved_at: DateTime.now, approved_by_id: by.id)
    end
  end

  private

  def ends_at_on_or_after_starts_at
    return if starts_at.blank? || ends_at.blank?
    errors.add(:ends_at, "must be on or after starts_at") if ends_at < starts_at
  end

  # Reject any cycle whose [starts_at, ends_at] window overlaps another
  # sibling cycle. Belt-and-suspenders: the contiguous-from-latest rule
  # below already implies append-only, but a defensive overlap check
  # catches misconfigured back-fills before they corrupt the ledger.
  def no_date_overlap_with_siblings
    return if starts_at.blank? || ends_at.blank? || enterprise_id.blank?
    overlap = self.class
      .where(enterprise_id: enterprise_id)
      .where.not(id: id)
      .where("starts_at <= ? AND ends_at >= ?", ends_at, starts_at)
      .exists?
    errors.add(:base, "overlaps another pay cycle for this enterprise") if overlap
  end

  # Enforce a contiguous, append-only timeline: a new cycle must start the
  # day after the latest existing sibling's ends_at. Lets the cadence change
  # mid-stream (twice_monthly → monthly) by picking up wherever the prior
  # cycle left off. The first cycle for an enterprise has no constraint.
  def starts_immediately_after_latest_sibling
    return if starts_at.blank? || enterprise_id.blank?
    latest = self.class
      .where(enterprise_id: enterprise_id)
      .where.not(id: id)
      .order(ends_at: :desc)
      .first
    return if latest.nil?
    expected = latest.ends_at + 1.day
    return if starts_at == expected
    errors.add(:starts_at, "must be #{expected} (the day after the previous cycle's ends_at #{latest.ends_at}) — pay cycles are a contiguous, append-only timeline")
  end

  # Soft-deletes are still destructive in spirit — they hide stubs that
  # may already be QBO-billed/paid, and re-creating a cycle for the same
  # window would silently bypass the contiguous-timeline invariant.
  # Refuse to destroy a cycle once ANY of its stubs has been accepted or
  # already has a qbo_bill_id attached.
  def reject_destroy_when_any_stub_is_payable_or_paid
    blocking = pay_stubs.where("accepted_at IS NOT NULL OR qbo_bill_id IS NOT NULL")
    return if blocking.none?
    raise CycleHasPayableStubsError,
      "PayCycle ##{id} cannot be destroyed: #{blocking.count} of its stubs are accepted or have a QBO bill. " \
      "Add a corrective ContributorAdjustment instead, or unaccept stubs first."
  end
end
