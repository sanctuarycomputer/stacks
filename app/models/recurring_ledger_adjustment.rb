class RecurringLedgerAdjustment < ApplicationRecord
  CADENCES = %w[monthly twice_monthly quarterly].freeze

  belongs_to :ledger
  has_one :enterprise, through: :ledger
  has_one :contributor, through: :ledger

  validates :amount, presence: true
  validates :cadence, inclusion: { in: CADENCES }
  validates :next_due_on, presence: true

  scope :active, -> { where(paused_at: nil) }
  scope :due, ->(on = Date.today) { where("next_due_on <= ?", on) }

  def paused?
    paused_at.present?
  end

  # Materialize one ContributorAdjustment for the current next_due_on, then
  # advance next_due_on by the row's cadence. Wrapped in a transaction so a
  # save failure on either side leaves the row queryable as still-due.
  # Returns the ContributorAdjustment that was created, or nil if the row is
  # paused.
  def materialize!
    return nil if paused?

    effective_on = next_due_on
    qa = ledger.enterprise.qbo_account
    adjustment = nil

    ActiveRecord::Base.transaction do
      adjustment = ContributorAdjustment.create!(
        ledger: ledger,
        amount: amount,
        description: description,
        effective_on: effective_on,
        qbo_account_id: qa&.id,
      )
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
