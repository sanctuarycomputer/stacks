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
    # MSO executive compensation, whatever Finance names the account. Without these an account called
    # "MSO Compensation" matches nothing above and the outlook would report total executive pay.
    /compensation/i, /\bmso\b/i, /executive/i,
  ].freeze

  def self.excluded?(*labels)
    labels.compact.any? { |l| PATTERNS.any? { |re| re.match?(l.to_s) } }
  end

  # The patterns are written for costs. In these sections a match is revenue
  # ("Consulting Income", "Management Fee Income"), not a payment to a person.
  INCOME_SECTIONS = ["Income", "Other Income"].freeze

  # A stored P&L's rows ([label, value]; a header has no value) with every people-cost row taken out: the
  # account's own row, everything under a people-cost header, and their "Total ..." rows. The financial outlook
  # applies the same test to the spend sections; here it applies everywhere except the income sections, so a
  # row outside any section Stacks recognises is filtered too. Section totals stay: they are the same
  # figures the enterprise snapshot already reports.
  def self.rows_without_people_costs(rows)
    rows = Array(rows)
    stack = []
    hidden_through = -1
    rows.each_with_index.filter_map do |row, i|
      next nil unless row.is_a?(Array)

      label = row[0].to_s
      hide = i <= hidden_through ||
             (!INCOME_SECTIONS.include?(stack.first) && excluded?(label, *stack.drop(1)))
      if hide && i > hidden_through
        # QuickBooks sometimes totals an account that also posts: hide through its "Total" row, children and all.
        closing = rows[(i + 1)..].index { |later| later.is_a?(Array) && later[0].to_s == "Total #{label}" }
        hidden_through = i + 1 + closing if closing
      end

      if row[1].nil?
        stack.push(label)
      elsif label.start_with?("Total ")
        opened = stack.rindex(label.delete_prefix("Total "))
        stack.slice!(opened..) if opened
      end

      hide ? nil : row
    end
  end
end
