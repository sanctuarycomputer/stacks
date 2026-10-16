module Mso
  # The other side of garden3d's invoices: each one, mirrored as a bill in the
  # QuickBooks of the enterprise it bills, from that enterprise's "garden3d,
  # LLC" vendor. Same number and date as the invoice, Net 15. Each invoice line
  # becomes a bill line on the account its item maps to in ACCOUNTS.
  #
  # NOTHING HERE RUNS UNATTENDED. sync_bill! writes to the paying enterprise's
  # QuickBooks and is reached only from an admin's click on the tracker
  # (app/admin/invoice_trackers.rb). Do not call it from a rake task, a job or
  # Stacks::Automator. It never marks a bill paid: Finance matches the payment.
  class IntercompanyBills
    class Error < StandardError; end
    class Misconfigured < Error; end
    class NotReady < Error; end
    class PaidBill < Error; end

    # Paying enterprise => garden3d invoice item => account number in the
    # paying enterprise's chart (Finance, 2026-10-16). An item with no entry
    # here refuses the bill rather than guess where it goes: Sanctuary has no
    # loans to repay.
    ACCOUNTS = {
      Enterprise::SANCTUARY_NAME => {
        "Managerial Services" => "8300",  # Management Fee Expense
      },
      Enterprise::INDEX_SPACE_NAME => {
        "Managerial Services" => "9100",  # Management Fee Expense
        "Loan Repayment" => "9500",       # Loan Repayments
      },
      Enterprise::USB_CLUB_NAME => {
        "Managerial Services" => "8200",  # Management Fee Expense
        "USB Loan Repayment" => "2510",   # Due to Garden3d
      },
    }.freeze
    DUE_DAYS = 15

    class << self
      # Creates the tracker's bill, or rewrites it to match the invoice as it
      # is now. WRITES TO THE PAYING ENTERPRISE'S QUICKBOOKS. Refuses a bill
      # with any payment. Returns the bill.
      def sync_bill!(invoice_tracker:)
        pass = invoice_tracker.invoice_pass
        unless invoice_tracker.garden3d? && pass.start_of_month >= InvoicePass::INTERCOMPANY_START
          raise Misconfigured, "InvoiceTracker #{invoice_tracker.id} is not one of " \
                               "#{Enterprise::GARDEN3D_NAME}'s intercompany invoices"
        end
        if invoice_tracker.qbo_invoice_id.blank?
          raise NotReady, "InvoiceTracker #{invoice_tracker.id} has no garden3d invoice yet. Generate it first."
        end

        payer = Mso::IntercompanyInvoices.payer_for!(invoice_tracker)
        payer_qbo = payer.qbo_account
        raise Misconfigured, "#{payer.name} has no QuickBooks account connected to Stacks" if payer_qbo.nil?
        accounts_by_item = ACCOUNTS[payer.name]
        raise Misconfigured, "Stacks has no bill accounts for #{payer.name} (Mso::IntercompanyBills::ACCOUNTS)" if accounts_by_item.nil?

        invoice = invoice_tracker.qbo_account.fetch_invoice_by_id(invoice_tracker.qbo_invoice_id)
        raise NotReady, "garden3d's QuickBooks did not return invoice #{invoice_tracker.qbo_invoice_id}" if invoice.nil?

        lines = bill_lines!(invoice, accounts_by_item, payer, payer_qbo)
        vendor = vendor!(payer, payer_qbo)
        term = net_15_term!(payer_qbo)

        # The row lock makes a double click wait, then update the bill the
        # first click made, instead of creating two. with_lock is a
        # transaction, so what must stick is decided in here and raised after.
        outcome, detail = invoice_tracker.with_lock do
          bill =
            if invoice_tracker.payer_qbo_bill_id.present?
              existing_bill!(invoice_tracker, payer, payer_qbo)
            else
              hand_made = bills_already_in_quickbooks(payer_qbo, vendor, invoice.doc_number)
              if hand_made.any?
                # Attach it rather than make a second; the next click updates it.
                invoice_tracker.update!(payer_qbo_bill_id: hand_made.first.id.to_s)
                next [:attached, hand_made]
              end
              Quickbooks::Model::Bill.new
            end
          if bill == :gone
            gone_id = invoice_tracker.payer_qbo_bill_id
            invoice_tracker.update!(payer_qbo_bill_id: nil)
            next [:gone, gone_id]
          end

          fill!(bill, invoice, vendor, term, lines, pass)
          service = Quickbooks::Service::Bill.new
          service.company_id = payer_qbo.realm_id
          service.access_token = payer_qbo.make_and_refresh_qbo_access_token
          saved = bill.id.present? ? service.update(bill) : service.create(bill)
          raise Error, "#{payer.name}'s QuickBooks did not confirm the bill" if saved.nil? || saved.id.blank?

          invoice_tracker.update!(payer_qbo_bill_id: saved.id.to_s)
          [:saved, saved]
        end

        case outcome
        when :saved
          detail
        when :attached
          raise NotReady, "#{payer.name}'s QuickBooks already has bill #{invoice.doc_number} from " \
                          "#{vendor.display_name} (id #{detail.map(&:id).join(', ')}). Stacks attached it and " \
                          "created nothing. Click again to update it to match the invoice."
        when :gone
          raise NotReady, "Bill #{detail} is no longer in #{payer.name}'s QuickBooks. Stacks detached it. " \
                          "Click again to create a new one."
        end
      end

      def bill_url(invoice_tracker)
        return nil if invoice_tracker.payer_qbo_bill_id.blank?
        "https://qbo.intuit.com/app/bill?&txnId=#{invoice_tracker.payer_qbo_bill_id}"
      end

      private

      # One bill line per invoice line with an amount, on its item's account.
      def bill_lines!(invoice, accounts_by_item, payer, payer_qbo)
        if invoice.doc_number.blank? || invoice.txn_date.blank?
          raise NotReady, "garden3d invoice #{invoice.id} has no number or date yet"
        end
        unless invoice.total.to_d.positive?
          raise NotReady, "garden3d invoice #{invoice.doc_number} is $0.00. Set its amount in QuickBooks first."
        end

        chart = payer_qbo.fetch_all_accounts
        invoice.line_items.select(&:sales_item?).reject { |line| line.amount.to_d.zero? }.map do |line|
          item = line.sales_line_item_detail&.item_ref&.name.to_s
          number = accounts_by_item[item]
          if number.nil?
            raise Misconfigured, "garden3d invoice #{invoice.doc_number} has a \"#{item}\" line, and Stacks has no " \
                                 "account for it in #{payer.name}'s books. No bill was written."
          end
          account = chart.find { |a| a.respond_to?(:acct_num) && a.acct_num.to_s == number }
          if account.nil?
            raise Misconfigured, "#{payer.name}'s QuickBooks has no account #{number} for \"#{item}\" lines. " \
                                 "No bill was written."
          end
          { amount: line.amount.to_d, description: line.description.presence || item, account: account }
        end
      end

      def vendor!(payer, payer_qbo)
        vendor_id = payer.g3d_qbo_vendor_id.to_s
        vendor = vendor_id.present? && payer_qbo.fetch_all_vendors.find { |v| v.id.to_s == vendor_id && v.active? }
        unless vendor
          raise Misconfigured, "#{payer.name}'s garden3d vendor (#{vendor_id.presence || 'not set'}) is not an " \
                               "active vendor in its QuickBooks. Set it on the enterprise's edit page."
        end
        vendor
      end

      def net_15_term!(payer_qbo)
        term = payer_qbo.fetch_all_terms.find { |candidate| candidate.due_days == DUE_DAYS }
        raise Misconfigured, "#{payer_qbo.enterprise.name}'s QuickBooks has no Net #{DUE_DAYS} term" if term.nil?
        term
      end

      # The tracker's bill, read now, or :gone if QuickBooks no longer has it.
      # Refuses one with any payment.
      def existing_bill!(invoice_tracker, payer, payer_qbo)
        bill =
          begin
            payer_qbo.fetch_bill_by_id(invoice_tracker.payer_qbo_bill_id)
          rescue StandardError => e
            raise unless e.message.to_s.start_with?("Object Not Found")

            return :gone
          end
        if bill.balance.to_d < bill.total.to_d
          raise PaidBill, "Bill #{bill.doc_number} in #{payer.name}'s QuickBooks has a payment against it. Stacks " \
                          "will not change it; adjust it there by hand."
        end
        bill
      end

      # One QuickBooks READ: bills from this vendor with this number.
      def bills_already_in_quickbooks(payer_qbo, vendor, doc_number)
        service = Quickbooks::Service::Bill.new
        service.company_id = payer_qbo.realm_id
        service.access_token = payer_qbo.make_and_refresh_qbo_access_token
        number = doc_number.to_s.gsub("'", "\\\\'")
        found = service.query("SELECT * FROM Bill WHERE DocNumber = '#{number}' AND VendorRef = '#{vendor.id}'",
                              per_page: 100)
        Array(found&.entries)
      end

      def fill!(bill, invoice, vendor, term, lines, pass)
        bill.vendor_ref = Quickbooks::Model::BaseReference.new(vendor.id)
        bill.doc_number = invoice.doc_number
        bill.txn_date = invoice.txn_date
        bill.due_date = invoice.txn_date + DUE_DAYS
        bill.sales_term_ref = Quickbooks::Model::BaseReference.new(term.name, value: term.id)
        bill.private_note = "garden3d invoice #{invoice.doc_number}, #{pass.invoice_month}"
        bill.line_items = lines.map do |data|
          line = Quickbooks::Model::BillLineItem.new(description: data[:description], amount: data[:amount])
          line.account_based_expense_item! do |detail|
            detail.account_ref = Quickbooks::Model::BaseReference.new(data[:account].id)
          end
          line
        end
        bill
      end
    end
  end
end
