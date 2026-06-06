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

# Three deletion scopes for the "off-platform payment offset" pattern:
#   :strict — negative CAs whose description references a Deel URL
#   :mid    — negative CAs whose description starts with "Misc payment:"
#             (covers Deel, Justworks, BUS, S-Corp draws, etc. — all
#             off-platform offsets entered by hand)
#   :broad  — every negative ContributorAdjustment
#
# Each scope assumes the corresponding QBO Bill that the CA was offsetting
# has since been marked Paid in QBO (so under the new rules it drops out
# of balance naturally).
def deletion_scope_matches?(li, scope)
  return false unless li.is_a?(ContributorAdjustment)
  return false unless li.amount.to_f < 0
  case scope
  when :strict then li.description.to_s.match?(/deel\.com/i)
  when :mid    then li.description.to_s.start_with?("Misc payment:")
  when :broad  then true
  end
end

def post_cutover_balance(ledger_items, scope:)
  ledger_items[:all].reduce({ balance: 0, unsettled: 0 }) do |acc, li|
    next acc if li.respond_to?(:deleted_at) && li.deleted_at.present?
    next acc if li.is_a?(DeelInvoiceAdjustment) # no longer deducts under new rules
    next acc if deletion_scope_matches?(li, scope) # treat as deleted

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

neg_ca_contrib_ids =
  ContributorAdjustment.where("amount < 0").joins(:ledger).pluck("ledgers.contributor_id").uniq

candidate_ids = (dia_contrib_ids + paid_host_contrib_ids + neg_ca_contrib_ids).uniq
puts "Candidates: #{candidate_ids.size} contributor(s)"
puts "  with DIA:                 #{dia_contrib_ids.size}"
puts "  with paid-in-QBO bills:    #{paid_host_contrib_ids.size}"
puts "  with negative CA rows:     #{neg_ca_contrib_ids.size}"
puts

results_per_scope = { strict: [], mid: [], broad: [] }

Contributor.unscoped.where(id: candidate_ids).find_each do |c|
  next if c.forecast_person.nil?
  c.preload_for_ledger_view!
  items = c.all_items_grouped_by_month(false)

  current = c.new_deal_balance(items)

  [:strict, :mid, :broad].each do |scope|
    proposed = post_cutover_balance(items, scope: scope)
    d_bal = (proposed[:balance] - current[:balance]).to_f.round(2)
    d_uns = (proposed[:unsettled] - current[:unsettled]).to_f.round(2)
    next if d_bal.abs < 0.01 && d_uns.abs < 0.01
    results_per_scope[scope] << {
      id: c.id,
      email: c.forecast_person.email,
      cur_bal: current[:balance].to_f.round(2),
      new_bal: proposed[:balance].to_f.round(2),
      d_bal: d_bal,
      d_uns: d_uns,
    }
  end
end

[:strict, :mid, :broad].each do |scope|
  affected = results_per_scope[scope]
  label = case scope
          when :strict then 'STRICT — delete CAs whose description references a Deel URL'
          when :mid    then 'MID    — delete CAs starting with "Misc payment:"'
          when :broad  then 'BROAD  — delete every negative CA'
          end
  puts '=' * 78
  puts "SCENARIO: #{label}"
  puts '=' * 78
  if affected.empty?
    puts "  Zero drift on all candidates — invariant holds."
    puts
    next
  end
  total_d_bal = affected.sum { |r| r[:d_bal] }.round(2)
  total_d_uns = affected.sum { |r| r[:d_uns] }.round(2)
  pos = affected.count { |r| r[:d_bal] > 0 }
  neg = affected.count { |r| r[:d_bal] < 0 }
  near_zero = affected.count { |r| r[:d_bal].abs < 1.0 }
  puts "  Affected:   #{affected.size} contributor(s) with non-zero delta"
  puts "  Δbalance:   #{total_d_bal} sum  (#{pos} UP, #{neg} DOWN, #{near_zero} within $1)"
  puts "  Δunsettled: #{total_d_uns}"
  puts
  puts "  Top 15 by |Δbalance|:"
  affected.sort_by { |r| -r[:d_bal].abs }.first(15).each do |r|
    puts "    ##{r[:id]} #{r[:email]}: $#{r[:cur_bal]} → $#{r[:new_bal]} (Δ#{r[:d_bal]})"
  end
  puts
end
