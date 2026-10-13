module Mso
  # garden3d's management fee income for a month: the accrual P&L row for
  # account 4100. This is the basis of the MSO compensation cap.
  #
  # Reads the stored report rows directly. QboProfitAndLossReport#find_row is
  # unusable here: it returns 0.0 when the label is not found, so a renamed
  # account would silently become a $0 cap, and it converts through Float.
  #
  # for_month on the current, unfinished month returns a partial figure: the
  # stored report is whatever the last nightly sync saw.
  class ManagementFeeIncome
    class Error < StandardError; end
    class RowMissing < Error; end
    class MalformedRow < Error; end
    class UnsyncedInvoice < Error; end
    class WrongAccount < Error; end
    class VarianceError < Error; end

    # "4100 Management Fee Income" today. Matching the account number alone
    # survives a rename of the account; "Total 4100 ..." and "41000 ..." do
    # not match.
    ACCOUNT_ROW = /\A4100\b/
    ZERO = BigDecimal("0")

    class << self
      def for_month(date)
        month = date.to_date.beginning_of_month
        label = month.strftime("%B %Y")
        report = report_for(month)
        rows = report.data.is_a?(Hash) ? report.data.dig("accrual", "rows") : nil
        raise RowMissing, "garden3d's P&L for #{label} has no accrual rows" unless rows.is_a?(Array)

        matches = rows.select { |row| row.is_a?(Array) && row[0].to_s.match?(ACCOUNT_ROW) }
        if matches.empty?
          raise RowMissing, "garden3d's accrual P&L for #{label} has no account 4100 row (#{rows.size} rows). " \
                            "No management fee was booked, or the account was renumbered."
        end
        if matches.size > 1
          raise RowMissing, "garden3d's accrual P&L for #{label} has #{matches.size} rows starting with 4100; " \
                            "refusing to guess which is management fee income"
        end

        value = matches.first[1].to_s.strip
        raise RowMissing, "garden3d's account 4100 row for #{label} has no amount" if value.empty?

        begin
          BigDecimal(value)
        rescue ArgumentError
          raise MalformedRow, "garden3d's account 4100 row for #{label} is not a number: #{value.inspect}"
        end
      end

      # Compares the 4100 total against what garden3d's management fee
      # invoices for the month actually charge on the Managerial Services
      # item. A difference means account 4100 holds income that is not a fee
      # line Stacks recognises: an outside customer, a fee billed on another
      # item, or an invoice dated in another month. The cap would be wrong.
      #
      # `invoices` lists each attached invoice with its total and its
      # Managerial Services subtotal, so a variance can be traced to one.
      #
      # Reads the stored invoice mirrors. Refresh them first
      # (Mso::IntercompanyInvoices.refresh!) if they may be stale.
      def reconcile(date)
        month = date.to_date.beginning_of_month
        account_total = for_month(month)
        invoices = fee_invoices_for(month)
        payer_total = invoices.sum(ZERO) { |invoice| invoice[:managerial_services] }
        {
          account_total: account_total,
          payer_total: payer_total,
          variance: account_total - payer_total,
          invoices: invoices,
        }
      end

      def reconcile!(date)
        result = reconcile(date)
        return result if result[:variance].zero?

        compared = result[:invoices].map do |invoice|
          "#{invoice[:qbo_id]} (total #{invoice[:total].to_s('F')}, " \
            "Managerial Services #{invoice[:managerial_services].to_s('F')})"
        end
        raise VarianceError, "garden3d's account 4100 reads #{result[:account_total].to_s('F')} for " \
                             "#{date.to_date.strftime('%B %Y')} but its management fee invoices charge " \
                             "#{result[:payer_total].to_s('F')} on Managerial Services (variance " \
                             "#{result[:variance].to_s('F')}). Invoices compared: " \
                             "#{compared.empty? ? 'none' : compared.join('; ')}"
      end

      private

      def report_for(month)
        qbo_account = garden3d_qbo_account
        persisted = QboProfitAndLossReport
          .where(qbo_account_id: qbo_account.id, starts_at: month, ends_at: month.end_of_month)
          .order(:id).last
        return persisted if persisted

        # Nothing stored for this month: fetch it once. `force` is the THIRD
        # POSITIONAL argument and must stay false -- true deletes the stored
        # rows the dashboard, the enterprise snapshot and two MCP tools read.
        QboProfitAndLossReport.find_or_fetch_for_range(month, month.end_of_month, false, qbo_account)
      end

      def garden3d_qbo_account
        qbo_account = QboAccount.where(enterprise_id: Enterprise.garden3d.id).order(:id).first
        raise Error, "#{Enterprise::GARDEN3D_NAME} has no connected QboAccount" if qbo_account.nil?
        qbo_account
      end

      # One entry per invoice attached to garden3d's pass for the month.
      # Fee income is counted by LINE, not by invoice total: an invoice can
      # also carry lines that are not fee income (a loan repayment), which
      # never post to 4100.
      def fee_invoices_for(month)
        garden3d_id = Enterprise.garden3d.id
        pass = InvoicePass.find_by(enterprise_id: garden3d_id, start_of_month: month)
        return [] if pass.nil?

        garden3d_account_ids = QboAccount.where(enterprise_id: garden3d_id).pluck(:id)
        trackers = InvoiceTracker.where(invoice_pass_id: pass.id).where.not(qbo_invoice_id: nil).order(:id).to_a

        trackers.map do |tracker|
          # The tracker edit form can attach an invoice from any QuickBooks
          # account, re-pointing qbo_account_id with it. Another company's
          # invoice is never garden3d's fee income.
          unless garden3d_account_ids.include?(tracker.qbo_account_id)
            raise WrongAccount, "InvoiceTracker #{tracker.id} on garden3d's pass points at QuickBooks account " \
                                "#{tracker.qbo_account_id}, which is not garden3d's"
          end

          # By the (account, id) pair, and stored data only. QboInvoice#data
          # fetches from QuickBooks when the stored jsonb is blank; an
          # unsynced invoice is unknown, not zero.
          mirror = QboInvoice.find_by(qbo_account_id: tracker.qbo_account_id, qbo_id: tracker.qbo_invoice_id)
          stored = mirror&.read_attribute(:data)
          if stored.blank?
            raise UnsyncedInvoice, "QuickBooks invoice #{tracker.qbo_invoice_id} on InvoiceTracker #{tracker.id} " \
                                   "has not been synced; refresh garden3d's pass from QuickBooks first"
          end

          fee_lines = (stored["line_items"] || []).select do |line|
            line.is_a?(Hash) &&
              line.dig("sales_line_item_detail", "item_ref", "name") == Mso::IntercompanyInvoices::ITEM_NAME
          end

          {
            tracker_id: tracker.id,
            qbo_id: tracker.qbo_invoice_id,
            total: stored_amount(stored["total"]),
            managerial_services: fee_lines.sum(ZERO) { |line| stored_amount(line["amount"]) },
          }
        end
      end

      def stored_amount(value)
        BigDecimal(value.to_s)
      rescue ArgumentError
        raise MalformedRow, "a stored QuickBooks amount is not a number: #{value.inspect}"
      end
    end
  end
end
