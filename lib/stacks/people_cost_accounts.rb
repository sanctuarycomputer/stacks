# P&L accounts that are payroll, benefits, contractors, payments to people or intercompany. HR and compensation
# stay walled: the financial outlook's spend by category never shows them, by name or by amount (2026-09-29).
# An account is excluded when its own label OR any parent header matches.
module Stacks::PeopleCostAccounts
  PATTERNS = [
    /salar/i, /wage/i, /payroll/i, /\bstaff\b/i, /instructor/i, /officer/i, /guaranteed payment/i, /bonus/i,
    /commission/i, /stipend/i, /profit ?shar/i, /payout/i, /reimburs/i, /\bpto\b/i, /time off/i,
    /benefit/i, /health/i, /medical/i, /dental/i, /vision/i, /401\(?k\)?/i, /retirement/i, /pension/i,
    /workers.?comp/i, /employer tax/i, /\bfica\b/i, /\bfuta\b/i, /\bsuta\b/i, /unemployment/i,
    /contractor/i, /contract labor/i, /freelanc/i, /consult/i, /\bpeo\b/i,
    # pass-through / clearing accounts for payments made on behalf of clients and people
    /misc(ellaneous)? payments/i, /payments offset/i, /pass.?through/i, /clearing/i,
    /justworks/i, /\bdeel\b/i, /gusto/i, /rippling/i, /trinet/i,
    /management fee/i, /intercompany/i, /inter-company/i, /due (to|from)/i,
  ].freeze

  def self.excluded?(*labels)
    labels.compact.any? { |l| PATTERNS.any? { |re| re.match?(l.to_s) } }
  end
end
