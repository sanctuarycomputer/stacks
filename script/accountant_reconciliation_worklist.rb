# Accountant-facing reconciliation worklist for the proposed cutover.
#
# Model under audit:
#   - Every negative ContributorAdjustment is deleted (they all represent
#     payments already made off-platform; positive CAs survive because
#     they're upward adjustments, not payment offsets)
#   - DeelInvoiceAdjustment no longer deducts (audit trail only)
#   - SyncsAsQboBill hosts drop out of balance when their QboBill mirror
#     is Paid
#
# After the accountant goes through every affected contributor's open
# QBO bills and marks the ones that have genuinely been paid, the
# Stacks balance should converge to the QBO truth.

QBO_HOST_KLASSES = [ContributorPayout, ContributorAdjustment, ProfitShare, Trueup, PayStub].freeze

def post_cutover_balance(ledger_items)
  ledger_items[:all].reduce({ balance: 0, unsettled: 0 }) do |acc, li|
    next acc if li.respond_to?(:deleted_at) && li.deleted_at.present?
    next acc if li.is_a?(DeelInvoiceAdjustment)
    next acc if li.is_a?(ContributorAdjustment) && li.amount.to_f < 0

    case li
    when ContributorPayout, ProfitShare, ContributorAdjustment, PayStub
      if li.payable?
        next acc if li.qbo_bill&.paid?
        acc[:balance] += li.amount
      else
        acc[:unsettled] += li.amount
      end
    when Trueup
      next acc if li.qbo_bill&.paid?
      acc[:balance] += li.amount
    when Reimbursement
      if li.accepted?
        acc[:balance] += li.amount
      else
        acc[:unsettled] += li.amount
      end
    end
    acc
  end
end

# Open QBO bills traceable to a contributor via any host class.
# Walk every host row that has a qbo_bill_id set, route through the
# per-class qbo_account_for_bill helper (ContributorPayout / PayStub /
# ProfitShare / Trueup don't have a qbo_account_id column — only
# ContributorAdjustment does — so a raw column lookup misses them).
open_bills_by_contributor = Hash.new { |h, k| h[k] = [] }

QBO_HOST_KLASSES.each do |klass|
  klass.where.not(qbo_bill_id: nil).includes(:ledger).find_each do |row|
    qb = row.qbo_bill rescue nil
    next if qb.nil? || qb.paid?
    contributor_id = row.ledger&.contributor_id
    next if contributor_id.nil?
    open_bills_by_contributor[contributor_id] << {
      host_class: klass.name,
      host_id: row.id,
      qbo_url: qb.qbo_url,
      balance: qb.total_amount.to_f,
    }
  end
end

dia_contrib_ids =
  DeelInvoiceAdjustment.joins(:ledger).where(deleted_at: nil).pluck("ledgers.contributor_id").uniq
neg_ca_contrib_ids =
  ContributorAdjustment.where("amount < 0").joins(:ledger).pluck("ledgers.contributor_id").uniq
candidate_ids = (dia_contrib_ids + neg_ca_contrib_ids + open_bills_by_contributor.keys).uniq

rows = []

Contributor.unscoped.where(id: candidate_ids).find_each do |c|
  next if c.forecast_person.nil?
  c.preload_for_ledger_view!
  items = c.all_items_grouped_by_month(false)

  current = c.new_deal_balance(items)
  proposed = post_cutover_balance(items)

  d_bal = (proposed[:balance] - current[:balance]).to_f.round(2)
  open_bills = open_bills_by_contributor[c.id] || []
  sum_open = open_bills.sum { |b| b[:balance] }.round(2)

  next if d_bal.abs < 0.01 && open_bills.empty?

  rows << {
    id: c.id,
    email: c.forecast_person.email,
    cur_bal: current[:balance].to_f.round(2),
    new_bal: proposed[:balance].to_f.round(2),
    d_bal: d_bal,
    open_bills: open_bills,
    sum_open: sum_open,
  }
end

total_d_bal = rows.sum { |r| r[:d_bal] }.round(2)
sum_all_open = rows.sum { |r| r[:sum_open] }.round(2)
up = rows.count { |r| r[:d_bal] > 0.01 }
down = rows.count { |r| r[:d_bal] < -0.01 }
flat = rows.count { |r| r[:d_bal].abs < 0.01 }

puts "Contributors needing accountant review: #{rows.size}"
puts "  with open QBO bills:        #{rows.count { |r| r[:open_bills].any? }} (sum: $#{sum_all_open})"
puts "  balance would go UP:        #{up} (under-recorded payments in QBO)"
puts "  balance would go DOWN:      #{down} (over-marked Paid in QBO OR missing offset CA)"
puts "  balance unchanged:          #{flat} (only have open bills to review)"
puts "  Σ Δbalance:                 #{total_d_bal}"
puts

# Group by direction
[
  ["UP (most likely cohort — accountant marks open bills as Paid where applicable)",     ->(r) { r[:d_bal] > 0.01 }],
  ["DOWN (review — Stacks expected this person to be owed money but QBO shows Paid)",   ->(r) { r[:d_bal] < -0.01 }],
  ["FLAT (only the open bills below need accountant confirmation)",                      ->(r) { r[:d_bal].abs < 0.01 && r[:open_bills].any? }],
].each do |label, filter|
  matching = rows.select(&filter).sort_by { |r| -r[:d_bal].abs }
  next if matching.empty?
  puts "=" * 78
  puts label
  puts "=" * 78
  matching.first(20).each do |r|
    puts "  ##{r[:id]} #{r[:email]}"
    puts "    Balance now: $#{r[:cur_bal]}    After cutover: $#{r[:new_bal]}    Δ#{r[:d_bal]}"
    if r[:open_bills].any?
      puts "    Open QBO bills (#{r[:open_bills].size} bills, sum $#{r[:sum_open]}):"
      r[:open_bills].first(5).each do |b|
        puts "      - #{b[:host_class]} ##{b[:host_id]}  $#{b[:balance].round(2)}  #{b[:qbo_url]}"
      end
      puts "      ... (#{r[:open_bills].size - 5} more)" if r[:open_bills].size > 5
    else
      puts "    (no open QBO bills — Δ implies missing data on either side)"
    end
    puts
  end
  if matching.size > 20
    puts "  ... and #{matching.size - 20} more in this cohort"
    puts
  end
end
