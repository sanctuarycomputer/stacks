module InvoicePayouts
  # Rules on a Build before it is written: would the invoice pay out more
  # than its cap? Also the row-by-row breakdown the admin overlay shows.
  #
  # The pool is everything that will sit on the tracker after the write, net
  # of commissions: the payees Build will pay, plus any existing payout the
  # write cannot remove because its QBO bill is already paid.
  class MarginCheck
    Row = Struct.new(:line, :billed, :commissions, :payouts, :allowed, :entries, keyword_init: true) do
      def basis
        billed - commissions
      end

      def over
        [(payouts - allowed).round(2), 0.0].max
      end

      def over?
        over > 1
      end

      def payout_percentage
        basis > 0 ? (payouts / basis * 100).round(1) : 0.0
      end

      def margin_percentage
        basis > 0 ? (100 - payouts / basis * 100).round(1) : 0.0
      end
    end

    attr_reader :build

    def initialize(build)
      @build = build
    end

    def retained_orphans
      build.retained_orphans
    end

    def retained_total
      retained_orphans.sum { |cp| cp.amount.to_f - cp.as_commission }.round(2)
    end

    def cap_calculation
      @cap_calculation ||= begin
        commissions = build.paid_commissions_by_line.dup
        retained_orphans.each do |cp|
          (cp.blueprint["Commission"] || []).each do |entry|
            line_id = entry["blueprint_metadata"].is_a?(Hash) ? entry["blueprint_metadata"]["id"]&.to_s : nil
            commissions[line_id] = commissions.fetch(line_id, 0.0) + entry["amount"].to_f
          end
        end
        Cap.new(build.invoice_tracker, commissions_by_line: commissions)
      end
    end

    def cap
      cap_calculation.cap
    end

    def post_commission_total
      cap_calculation.post_commission_total
    end

    def pool
      (build.paid_payees.sum { |p| p.amount - p.commission_amount } + retained_total).round(2)
    end

    def breached?
      pool > cap + 1 # a dollar of slack for rounding, as the save-time validation allows
    end

    def over_by
      [(pool - cap).round(2), 0.0].max
    end

    def payout_percentage
      percentage_of_total(pool)
    end

    def cap_percentage
      percentage_of_total(cap)
    end

    def rows
      @rows ||= build.lines.map do |line|
        line_id = line.qbo_line_item["id"].to_s
        # From the cap, not the build: the cap also takes off commissions
        # carried by payouts that cannot be removed.
        commissions = cap_calculation.commission_for(line_id)
        paid_entries = line.entries.select { |e| e.role != "Commission" && build.paid?(e.payee) }
        Row.new(
          line: line,
          billed: line.billed,
          commissions: commissions,
          payouts: paid_entries.sum(&:amount).round(2),
          allowed: ((line.billed - commissions) * (1 - cap_calculation.treasury_share_for(line_id))).to_f.round(2),
          entries: line.entries,
        )
      end
    end

    # Whatever is on the invoice but not on a blueprint line (recurring
    # charges, discounts), so the table adds up to the totals above it.
    def other_billed
      (build.invoice_tracker.total.to_f - rows.sum(&:billed)).round(2)
    end

    def other_allowed
      (cap - rows.sum(&:allowed)).round(2)
    end

    private

    def percentage_of_total(amount)
      post_commission_total > 0 ? (amount / post_commission_total * 100).round(1) : 0.0
    end
  end
end
