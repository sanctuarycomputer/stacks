module Studios
  module Snapshots
    # Monthly P&L totals for a studio from qbo_profit_and_loss_line_items.
    # Returns { "cash" => { Date => {income:, cost_of_goods_sold:, expenses:,
    # net_operating_income:} }, "accrual" => ... } with Float values; months
    # with no line items are absent.
    #
    # Replicates Studio#profit_and_loss_for_period / find_row semantics
    # exactly: FIRST matching row by report position (never SUM — a report
    # can hold both a section row and a "Total …" row matching the same
    # substring), 0.0 default when no row matches.
    class PnlByMonth
      def self.call(studio:, from:, through:, qbo_account: Enterprise.sanctuary.qbo_account)
        new(studio, from, through, qbo_account).call
      end

      G3D_LABELS = [
        "Total Income",
        "Total Cost of Goods Sold",
        "Total Expenses",
        "Net Operating Income",
      ].freeze

      def initialize(studio, from, through, qbo_account)
        @studio = studio
        @from = from.beginning_of_month
        @through = through
        @qbo_account = qbo_account
      end

      def call
        candidates = candidate_rows
        out = { "cash" => {}, "accrual" => {} }
        candidates
          .group_by { |method, starts_at, _pos, _label, _amount| [method, starts_at] }
          .each do |(method, starts_at), rows|
            # rows are position-ordered (query orders by position)
            labels_and_amounts = rows.map { |_m, _s, _p, label, amount| [label, amount.to_f] }
            out[method][starts_at] = totals_for(labels_and_amounts)
          end
        out
      end

      private

      def candidate_rows
        QboProfitAndLossLineItem
          .where(qbo_account_id: @qbo_account.id, starts_at: @from..@through)
          .where(candidate_predicate)
          .order(:accounting_method, :starts_at, :position)
          .pluck(:accounting_method, :starts_at, :position, :label, :amount)
      end

      def candidate_predicate
        if @studio.is_garden3d?
          QboProfitAndLossLineItem.arel_table[:label].in(G3D_LABELS)
        else
          p = ActiveRecord::Base.sanitize_sql_like(@studio.accounting_prefix.to_s)
          ActiveRecord::Base.sanitize_sql_array([
            "(label LIKE :income OR (label LIKE 'Total%' AND label LIKE :cos) OR label LIKE :tools)",
            income: "%Revenue - #{p}%",
            cos: "%COS - #{p}%",
            tools: "%Tools and Subscriptions - #{p}%",
          ])
        end
      end

      # first_match mirrors find_row: first row (by position) passing the
      # Ruby predicate; 0.0 when none does.
      def first_match(labels_and_amounts)
        row = labels_and_amounts.find { |label, _| yield(label) }
        row ? row[1] : 0.0
      end

      def totals_for(labels_and_amounts)
        if @studio.is_garden3d?
          {
            income: first_match(labels_and_amounts) { |l| l == "Total Income" },
            cost_of_goods_sold: first_match(labels_and_amounts) { |l| l == "Total Cost of Goods Sold" },
            expenses: first_match(labels_and_amounts) { |l| l == "Total Expenses" },
            net_operating_income: first_match(labels_and_amounts) { |l| l == "Net Operating Income" },
          }
        else
          prefix = @studio.accounting_prefix
          income = first_match(labels_and_amounts) { |l| l.include?("Revenue - #{prefix}") }
          cos = first_match(labels_and_amounts) { |l| l.start_with?("Total") && l.include?("COS - #{prefix}") }
          expenses = first_match(labels_and_amounts) { |l| l.include?("Tools and Subscriptions - #{prefix}") }
          {
            income: income,
            cost_of_goods_sold: cos - expenses,
            expenses: expenses,
            net_operating_income: income - cos,
          }
        end
      end
    end
  end
end
