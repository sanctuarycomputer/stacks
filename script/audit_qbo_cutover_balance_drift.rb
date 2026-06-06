# Dry-run audit for the QBO-cutover balance invariant.
#
# What it does: for every contributor whose balance could plausibly shift
# under the proposed cutover (anyone with a deducting DeelInvoiceAdjustment
# OR a paid-in-QBO bill), compute their current balance and their would-be
# balance under the new rules. Report non-zero deltas.
#
# Run with: bundle exec rails runner script/audit_qbo_cutover_balance_drift.rb
#
# New-rule semantics:
#   - DeelInvoiceAdjustment no longer affects balance (deducts_balance? → false going forward)
#   - SyncsAsQboBill hosts (ContributorPayout / ContributorAdjustment / ProfitShare /
#     Trueup / PayStub) drop out of balance when their QBO Bill mirror is Paid

QBO_HOST_KLASSES = [ContributorPayout, ContributorAdjustment, ProfitShare, Trueup, PayStub].freeze

def post_cutover_balance(ledger_items)
  ledger_items[:all].reduce({ balance: 0, unsettled: 0 }) do |acc, li|
    next acc if li.respond_to?(:deleted_at) && li.deleted_at.present?
    next acc if li.is_a?(DeelInvoiceAdjustment) # no longer deducts under new rules

    if li.is_a?(ContributorPayout)
      if li.payable?
        next acc if li.qbo_bill&.paid?
        acc[:balance] += li.amount
      else
        acc[:unsettled] += li.amount
      end
    elsif li.is_a?(Reimbursement)
      if li.accepted?
        acc[:balance] += li.amount
      else
        acc[:unsettled] += li.amount
      end
    elsif li.is_a?(Trueup)
      next acc if li.qbo_bill&.paid?
      acc[:balance] += li.amount
    elsif li.is_a?(ProfitShare)
      if li.payable?
        next acc if li.qbo_bill&.paid?
        acc[:balance] += li.amount
      else
        acc[:unsettled] += li.amount
      end
    elsif li.is_a?(ContributorAdjustment)
      if li.payable?
        next acc if li.qbo_bill&.paid?
        acc[:balance] += li.amount
      else
        acc[:unsettled] += li.amount
      end
    elsif li.is_a?(PayStub)
      if li.payable?
        next acc if li.qbo_bill&.paid?
        acc[:balance] += li.amount
      else
        acc[:unsettled] += li.amount
      end
    end
    acc
  end
end

# Candidates: anyone with at least one row that the cutover could touch.
dia_contrib_ids =
  DeelInvoiceAdjustment.joins(:ledger).where(deleted_at: nil).pluck("ledgers.contributor_id").uniq
paid_qbo_pairs =
  QboBill.pluck(:qbo_account_id, :qbo_id, :data).filter_map do |qa_id, qbo_id, data|
    balance = data&.dig("balance")
    next nil if balance.nil?
    next nil unless balance.to_f <= 0
    [qa_id, qbo_id]
  end

paid_host_contrib_ids = QBO_HOST_KLASSES.flat_map do |klass|
  next [] unless klass.column_names.include?("qbo_account_id") && klass.column_names.include?("qbo_bill_id")
  paid_qbo_pairs.flat_map do |qa_id, qbo_id|
    klass.where(qbo_account_id: qa_id, qbo_bill_id: qbo_id).joins(:ledger).pluck("ledgers.contributor_id")
  end
end.uniq

candidate_ids = (dia_contrib_ids + paid_host_contrib_ids).uniq
puts "Candidates: #{candidate_ids.size} contributor(s) (#{dia_contrib_ids.size} have DIA, #{paid_host_contrib_ids.size} have paid-in-QBO bills)"
puts

affected = []

Contributor.unscoped.where(id: candidate_ids).find_each do |c|
  next if c.forecast_person.nil?
  c.preload_for_ledger_view!
  items = c.all_items_grouped_by_month(false)

  current = c.new_deal_balance(items)
  proposed = post_cutover_balance(items)

  d_bal = (proposed[:balance] - current[:balance]).to_f.round(2)
  d_uns = (proposed[:unsettled] - current[:unsettled]).to_f.round(2)
  next if d_bal.abs < 0.01 && d_uns.abs < 0.01

  affected << {
    id: c.id,
    email: c.forecast_person.email,
    cur_bal: current[:balance].to_f.round(2),
    new_bal: proposed[:balance].to_f.round(2),
    d_bal: d_bal,
    d_uns: d_uns,
  }
end

puts "Affected: #{affected.size} contributor(s) with non-zero delta"
puts
if affected.any?
  total_d_bal = affected.sum { |r| r[:d_bal] }.round(2)
  total_d_uns = affected.sum { |r| r[:d_uns] }.round(2)
  pos = affected.count { |r| r[:d_bal] > 0 }
  neg = affected.count { |r| r[:d_bal] < 0 }
  puts "  Sum Δbalance: #{total_d_bal} (Δunsettled: #{total_d_uns})"
  puts "  #{pos} would go UP (under-deducted historically), #{neg} would go DOWN (over-deducted)"
  puts
  puts "  Top 20 by |Δbalance|:"
  affected.sort_by { |r| -r[:d_bal].abs }.first(20).each do |r|
    puts "    ##{r[:id]} #{r[:email]}: $#{r[:cur_bal]} → $#{r[:new_bal]} (Δ#{r[:d_bal]})"
  end
end
