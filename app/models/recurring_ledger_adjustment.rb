class RecurringLedgerAdjustment < ApplicationRecord
  CADENCES = %w[monthly twice_monthly quarterly].freeze

  belongs_to :ledger
  has_one :enterprise, through: :ledger
  has_one :contributor, through: :ledger

  validates :amount, presence: true
  validates :cadence, inclusion: { in: CADENCES }
  validates :next_due_on, presence: true
  # materialize! uses skip_qbo_bound_negative_check to bypass the per-row
  # validation so a LEGACY-era recurring deduction keeps materializing after
  # its ledger is flipped. But operators must NOT be able to create a NEW
  # negative recurring on an already-qbo_bound ledger — every materialization
  # would land as an audit-only CA the qbo_bound balance ignores, so the
  # "deduction" never actually deducts. Catch it here at the source.
  validate :no_new_negative_on_qbo_bound_ledger, on: :create

  def no_new_negative_on_qbo_bound_ledger
    return unless ledger&.qbo_bound? && amount&.negative?
    errors.add(
      :amount,
      "cannot create a negative recurring on a QBO-bound ledger — every materialized row would be audit-only and never deduct from the balance.",
    )
  end

  scope :active, -> { where(paused_at: nil) }
  scope :due, ->(on = Date.today) { where("next_due_on <= ?", on) }

  def paused?
    paused_at.present?
  end

  # Materialize one ContributorAdjustment for the current next_due_on, then
  # advance next_due_on by the row's cadence. Wrapped in a transaction so a
  # save failure on either side leaves the row queryable as still-due.
  # Returns the ContributorAdjustment that was created, or nil if the row is
  # paused / auto-paused.
  def materialize!
    return nil if paused?

    # Auto-pause if the recurring is a NEGATIVE CA on a now-qbo_bound ledger:
    # we'd bypass the create-time guard and insert an audit-only row that the
    # qbo_bound balance silently ignores. The recurring "deduction" would never
    # actually deduct (contributor over-paid every cycle until someone notices).
    # Pause instead so the row stops re-materializing AND surfaces as needing
    # operator attention rather than running fire-and-forget.
    if ledger.qbo_bound? && amount.to_f.negative?
      update!(paused_at: Time.current)
      Rails.logger.warn("[recurring_ledger_adjustment] ##{id} auto-paused: negative CA on qbo_bound ledger ##{ledger_id} would land as audit-only.")
      return nil
    end

    effective_on = next_due_on
    qa = ledger.enterprise.qbo_account
    adjustment = nil

    ActiveRecord::Base.transaction do
      adjustment = ContributorAdjustment.new(
        ledger: ledger,
        amount: amount,
        description: description,
        effective_on: effective_on,
        qbo_account_id: qa&.id,
      )
      # The recurring row was set up deliberately — bypass the qbo_bound
      # negative-CA guard so a legacy-era recurring deduction keeps materializing
      # after the ledger gets flipped to qbo_bound (the auto-pause above means
      # the only rows reaching here are non-negative or on a legacy ledger).
      adjustment.skip_qbo_bound_negative_check = true
      adjustment.save!
      update!(
        last_materialized_on: effective_on,
        next_due_on: advance(effective_on),
      )
    end

    adjustment
  end

  # Returns the date after `from` according to the row's cadence. monthly
  # adds one month; twice_monthly alternates between the 1st and 15th;
  # quarterly adds three months.
  def advance(from)
    case cadence
    when "monthly"
      from + 1.month
    when "twice_monthly"
      if from.day < 15
        from.change(day: 15)
      else
        (from + 1.month).beginning_of_month
      end
    when "quarterly"
      from + 3.months
    else
      raise ArgumentError, "unknown cadence #{cadence.inspect}"
    end
  end
end
