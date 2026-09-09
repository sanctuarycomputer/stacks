# Forward-looking contributor earnings, priced from the local Runn mirror
# with the same rules the invoice pass and pay cycles apply. See
# docs/superpowers/specs/2026-09-08-contributor-payment-projections-design.md.
module ContributorProjections
  MONTHS_AHEAD = 3
  STALE_AFTER_DAYS = 2

  KIND_ORDER = %i[
    individual_contributor pay_stub account_lead project_lead
    account_lead_surplus project_lead_surplus commission recurring_adjustment
  ].freeze

  # Line kinds whose `hours` are the payee's own worked hours (a constant
  # inside a `Struct.new do` block lands on this module anyway, so define it
  # here explicitly).
  HOURS_KINDS = %i[individual_contributor pay_stub].freeze

  # System.first, NOT System.instance: instance is memoized for the life of
  # the process, so a web worker would never see a newer sync stamp.
  def self.runn_synced_at
    System.first&.runn_synced_at
  end

  def self.stale?(as_of, today: Date.today)
    as_of.nil? || as_of.to_date < today - STALE_AFTER_DAYS
  end
end
