# For each contributor whose post-cutover balance goes UP, decompose the
# delta into its three drivers and print row-level detail.
#
# Math:
#   Δ = balance_new − balance_current
#     = (positive hosts that stay in balance)
#     − (positive hosts in balance now − DIA total − |neg CA total|)
#     = DIA_total + |neg_CA_total| − paid_host_drops
#
# So a contributor goes UP exactly when the deductions we remove
# (DIAs + negative CAs) exceed the positive hosts that drop out via
# Paid QBO bills. The per-row detail tells us WHICH deductions weren't
# matched by a Paid bill.

QBO_HOST_KLASSES = [ContributorPayout, ContributorAdjustment, ProfitShare, Trueup, PayStub].freeze

def eligible_ledger_ids_for(contributor)
  contributor.ledgers.includes(:enterprise).filter_map do |l|
    qa = l.enterprise.qbo_account
    next nil if qa.nil?
    vendor = contributor.qbo_vendor_for(qa)
    next nil if vendor.nil?
    l.id
  end.to_set
end

def safe_qbo_bill(li)
  li.qbo_bill
rescue StandardError
  nil
end

def breakdown(items, eligible_ids)
  out = {
    dias: [],            # [li]
    neg_cas: [],         # [li]
    pos_hosts_paid: [],  # [li] — drop out under cutover
    pos_hosts_open: [],  # [li] — have a QBO bill but not paid (stay)
    pos_hosts_nobill: [],# [li] — no QBO bill at all (stay)
  }

  items[:all].each do |li|
    next unless li.respond_to?(:ledger_id) && eligible_ids.include?(li.ledger_id)
    next if li.respond_to?(:deleted_at) && li.deleted_at.present?

    case li
    when DeelInvoiceAdjustment
      out[:dias] << li if li.deducts_balance?
    when ContributorAdjustment
      if li.amount.to_f < 0
        out[:neg_cas] << li
      elsif li.payable?
        qb = safe_qbo_bill(li)
        if qb&.paid?
          out[:pos_hosts_paid] << [li, qb]
        elsif qb
          out[:pos_hosts_open] << [li, qb]
        else
          out[:pos_hosts_nobill] << li
        end
      end
    when ContributorPayout, ProfitShare, PayStub
      next unless li.payable?
      qb = safe_qbo_bill(li)
      if qb&.paid?
        out[:pos_hosts_paid] << [li, qb]
      elsif qb
        out[:pos_hosts_open] << [li, qb]
      else
        out[:pos_hosts_nobill] << li
      end
    when Trueup
      qb = safe_qbo_bill(li)
      if qb&.paid?
        out[:pos_hosts_paid] << [li, qb]
      elsif qb
        out[:pos_hosts_open] << [li, qb]
      else
        out[:pos_hosts_nobill] << li
      end
    end
  end

  out
end

def sum_amount(rows)
  rows.sum { |r| (r.is_a?(Array) ? r[0] : r).amount.to_f }.round(2)
end

def classify(dia_total, neg_ca_total, paid_total)
  removed = dia_total + neg_ca_total
  if neg_ca_total > 0 && dia_total < 0.01
    "NEG-CA-DRIVEN"
  elsif dia_total > 0 && neg_ca_total < 0.01
    "DIA-DRIVEN"
  elsif neg_ca_total > 0 && dia_total > 0
    "BOTH"
  else
    "?"
  end
end

# Candidate set — same as the worklist
dia_contrib_ids =
  DeelInvoiceAdjustment.joins(:ledger).where(deleted_at: nil).pluck("ledgers.contributor_id").uniq
neg_ca_contrib_ids =
  ContributorAdjustment.where("amount < 0").joins(:ledger).pluck("ledgers.contributor_id").uniq

# We need open-bills too so we can match the worklist's "UP" set definitionally,
# but the candidate set itself only matters for selecting whom to scan.
qbo_host_contrib_ids = QBO_HOST_KLASSES.flat_map do |klass|
  klass.where.not(qbo_bill_id: nil).joins(:ledger).pluck("ledgers.contributor_id")
end.uniq

candidate_ids = (dia_contrib_ids + neg_ca_contrib_ids + qbo_host_contrib_ids).uniq

results = []

Contributor.unscoped.where(id: candidate_ids).find_each do |c|
  next if c.forecast_person.nil?
  eligible_ids = eligible_ledger_ids_for(c)
  next if eligible_ids.empty?

  c.preload_for_ledger_view!
  items = c.all_items_grouped_by_month(false)

  bd = breakdown(items, eligible_ids)

  dia_total      = sum_amount(bd[:dias])
  neg_ca_total   = sum_amount(bd[:neg_cas]).abs
  paid_total     = sum_amount(bd[:pos_hosts_paid])
  open_total     = sum_amount(bd[:pos_hosts_open])
  nobill_total   = sum_amount(bd[:pos_hosts_nobill])

  # Δ = dia + neg_ca − paid
  d_bal = (dia_total + neg_ca_total - paid_total).round(2)
  next if d_bal < 0.01

  results << {
    c: c,
    bd: bd,
    dia_total: dia_total,
    neg_ca_total: neg_ca_total,
    paid_total: paid_total,
    open_total: open_total,
    nobill_total: nobill_total,
    d_bal: d_bal,
    klass: classify(dia_total, neg_ca_total, paid_total),
  }
end

results.sort_by! { |r| -r[:d_bal] }

puts "#{results.size} contributors with Δbalance > 0"
puts
puts "Pattern distribution:"
results.group_by { |r| r[:klass] }.sort_by { |_, rs| -rs.size }.each do |k, rs|
  total = rs.sum { |r| r[:d_bal] }.round(2)
  puts "  #{k.ljust(20)}  #{rs.size} contributors   Σ Δ +$#{total}"
end
puts

results.each_with_index do |r, idx|
  c = r[:c]
  bd = r[:bd]
  puts "=" * 78
  puts "#{idx + 1}. ##{c.id} #{c.forecast_person.email}  [#{r[:klass]}]"
  puts "   Δ = +$#{r[:d_bal]}   (DIA $#{r[:dia_total]} + |negCA| $#{r[:neg_ca_total]} − paidQBO $#{r[:paid_total]})"
  puts "   Positive hosts still on the books after cutover:"
  puts "     - open QBO bills (will drop when accountant marks Paid):  $#{r[:open_total]} (#{bd[:pos_hosts_open].size} rows)"
  puts "     - no QBO bill at all (will NEVER drop, but never deducted via QBO either): $#{r[:nobill_total]} (#{bd[:pos_hosts_nobill].size} rows)"
  puts

  if bd[:neg_cas].any?
    puts "   Negative CAs being deleted (#{bd[:neg_cas].size}, $#{r[:neg_ca_total]}):"
    bd[:neg_cas].first(8).each do |ca|
      desc = ca.description.to_s[0, 70]
      puts "     - CA ##{ca.id}  $#{ca.amount.to_f.round(2)}  #{ca.created_at.to_date}  #{desc}"
    end
    puts "     ... (#{bd[:neg_cas].size - 8} more)" if bd[:neg_cas].size > 8
    puts
  end

  if bd[:dias].any?
    puts "   DIAs being ignored (#{bd[:dias].size}, $#{r[:dia_total]}):"
    bd[:dias].first(8).each do |dia|
      desc = dia.description.to_s[0, 70]
      puts "     - DIA ##{dia.id}  $#{dia.amount.to_f.round(2)}  #{dia.date_submitted}  #{dia.deel_status}  #{desc}"
    end
    puts "     ... (#{bd[:dias].size - 8} more)" if bd[:dias].size > 8
    puts
  end

  if bd[:pos_hosts_paid].any?
    puts "   Positive hosts dropping out via Paid QBO bills (#{bd[:pos_hosts_paid].size}, $#{r[:paid_total]}):"
    bd[:pos_hosts_paid].first(5).each do |li, qb|
      puts "     - #{li.class.name} ##{li.id}  $#{li.amount.to_f.round(2)}  #{qb.qbo_url}"
    end
    puts "     ... (#{bd[:pos_hosts_paid].size - 5} more)" if bd[:pos_hosts_paid].size > 5
    puts
  end

  if bd[:pos_hosts_open].any?
    puts "   Positive hosts with OPEN QBO bills (will drop when accountant marks Paid):"
    bd[:pos_hosts_open].first(5).each do |li, qb|
      puts "     - #{li.class.name} ##{li.id}  $#{li.amount.to_f.round(2)}  #{qb.qbo_url}"
    end
    puts "     ... (#{bd[:pos_hosts_open].size - 5} more)" if bd[:pos_hosts_open].size > 5
    puts
  end

  if bd[:pos_hosts_nobill].any?
    puts "   Positive hosts with NO QBO bill at all (these never synced):"
    bd[:pos_hosts_nobill].first(5).each do |li|
      puts "     - #{li.class.name} ##{li.id}  $#{li.amount.to_f.round(2)}  ledger=#{li.ledger_id}"
    end
    puts "     ... (#{bd[:pos_hosts_nobill].size - 5} more)" if bd[:pos_hosts_nobill].size > 5
    puts
  end
end
