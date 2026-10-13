module Mso
  # The QuickBooks side of garden3d's invoices to the enterprises it bills.
  # InvoicePass#make_trackers! makes one tracker per enterprise; this makes
  # each tracker's $0.00 draft in garden3d's QuickBooks, with one Managerial
  # Services line for the management fee. Finance sets the amount there, adds
  # any other lines (a loan repayment, say) and sends it. Stacks never writes
  # an amount and never sends an invoice.
  #
  # NOTHING HERE RUNS UNATTENDED. push_invoice! writes to QuickBooks and is
  # reached only from an admin's click, through InvoiceTracker#make_invoice!
  # (app/admin/invoice_passes.rb, app/admin/invoice_trackers.rb). Do not call
  # it from a rake task, a job or Stacks::Automator.
  class IntercompanyInvoices
    class Error < StandardError; end
    class Misconfigured < Error; end
    class PushFailed < Error; end
    class AlreadyInvoiced < Error; end
    class RefreshFailed < Error; end

    LINE_DESCRIPTION = "Management fee"
    # Resolved by name in garden3d's QuickBooks. The QBO default item
    # "Services" posts to the same income account, so falling back to it would
    # work and be wrong; a missing item raises instead.
    ITEM_NAME = "Managerial Services"
    ZERO = BigDecimal("0")

    RefreshRun = Struct.new(:attempted, :succeeded, :detached, :failed, keyword_init: true)

    class << self
      # Creates the $0.00 draft for one tracker in garden3d's QuickBooks and
      # attaches it. WRITES TO QUICKBOOKS. Raises on every failure; it never
      # returns without having created the invoice.
      #
      # August, September and October 2026 were invoiced by hand before this
      # shipped. The pre-flight read finds each of those invoices, refuses to
      # make a second, and lists it on the tracker's edit page to be attached.
      def push_invoice!(invoice_tracker:)
        pass = invoice_tracker.invoice_pass
        unless pass.intercompany? && invoice_tracker.blueprint.nil?
          raise Misconfigured, "InvoiceTracker #{invoice_tracker.id} is not one of " \
                               "#{Enterprise::GARDEN3D_NAME}'s intercompany invoices"
        end
        assert_no_invoice!(invoice_tracker)

        qbo_account = invoice_tracker.qbo_account
        unless qbo_account.enterprise_id == pass.enterprise_id
          raise Misconfigured, "InvoiceTracker #{invoice_tracker.id} is bound to a QuickBooks account that is " \
                               "not #{pass.enterprise.name}'s"
        end

        payer = payer_for!(invoice_tracker)
        item = managerial_services_item!(qbo_account)
        term = net_15_term!(qbo_account)
        customer = customer_for!(payer, qbo_account)

        already_in_quickbooks = []
        # The row lock makes a double click wait, then fail on the re-check,
        # instead of creating two drafts.
        mirror = invoice_tracker.with_lock do
          assert_no_invoice!(invoice_tracker)
          # The last thing before the write: does QuickBooks already have this
          # month's invoice for this customer? A hand-made one, or our own
          # from an attempt whose response never arrived.
          already_in_quickbooks = invoices_already_in_quickbooks(qbo_account, customer, pass, payer)
          # Refused below, OUTSIDE the lock: with_lock is a transaction, and
          # raising in here would roll back the mirror rows the refusal makes.
          next if already_in_quickbooks.any?

          created = create_draft!(qbo_account, pass, customer, item, term)

          begin
            mirror = QboInvoice.find_or_create_by!(qbo_id: created.id.to_s, qbo_account: qbo_account) do |row|
              # Store what QuickBooks returned. A blank mirror would make
              # QboInvoice#data fetch from QuickBooks on first read.
              row.data = created.as_json
            end
            invoice_tracker.update!(qbo_invoice_id: created.id.to_s)
            mirror
          rescue ActiveRecord::ActiveRecordError => e
            raise PushFailed, "QuickBooks invoice #{created.id} was created for #{payer.name} but Stacks could " \
                              "not record it (#{e.message}). Try again: Stacks will find that invoice in " \
                              "QuickBooks, refuse to make another, and list it on the tracker's edit page " \
                              "for you to attach."
          end
        end
        return mirror if already_in_quickbooks.empty?

        refuse_already_invoiced!(qbo_account, already_in_quickbooks, pass, payer)
      end

      # Re-reads each attached invoice from QuickBooks so its status, total
      # and balance are current. A QuickBooks READ; it writes nothing there.
      #
      # QboInvoice#sync! swallows every error and returns false, so its return
      # value alone cannot be trusted:
      #   - true-ish: the mirror now holds what QuickBooks says   -> succeeded
      #   - false, mirror row gone: QuickBooks no longer has the invoice; the
      #     row was destroyed and the tracker detached             -> detached
      #   - false, mirror row still there: the read failed and the
      #     row is STALE                                           -> failed
      def refresh!(invoice_pass:)
        unless invoice_pass.garden3d?
          raise Error, "InvoicePass #{invoice_pass.id} belongs to #{invoice_pass.enterprise.name}, not " \
                       "#{Enterprise::GARDEN3D_NAME}"
        end
        run = RefreshRun.new(attempted: 0, succeeded: 0, detached: 0, failed: [])

        InvoiceTracker.where(invoice_pass_id: invoice_pass.id).where.not(qbo_invoice_id: nil).order(:id).each do |tracker|
          # By the (account, id) pair, never through the association.
          mirror = QboInvoice.find_by(qbo_account_id: tracker.qbo_account_id, qbo_id: tracker.qbo_invoice_id)
          next if mirror.nil?

          run.attempted += 1
          if mirror.sync!
            run.succeeded += 1
          elsif QboInvoice.exists?(mirror.id)
            run.failed << tracker
          else
            run.detached += 1
          end
        end

        run
      end

      # Has garden3d been paid the fee it charged for this pass's month?
      # THE ENTRY POINT FOR ANY PAYABILITY DECISION.
      #
      # Reads every attached invoice from QuickBooks first, because the stored
      # copy starts life as an unsent $0.00 draft and nothing else updates it.
      # If any invoice cannot be read it RAISES: an answer from a stale copy
      # could say "nobody was charged" about an invoice that is unpaid.
      #
      # The answer itself is InvoicePass#management_fee_collected?, the pure
      # rule, asked of the refreshed mirrors -- so the two entry points can
      # never disagree about what "collected" means. That rule fails closed
      # on everything Stacks cannot vouch for. It answers false while:
      #   - any enterprise garden3d bills has no tracker on the pass;
      #   - any payer's tracker has NO invoice attached (one made by hand, or
      #     one this refresh just detached because QuickBooks no longer has
      #     it, may be an unpaid charge);
      #   - any attached invoice is dated outside the pass month, or has no
      #     readable date;
      #   - garden3d's mirror holds an invoice to a payer, dated in the pass
      #     month, that is not attached to this pass (a second or hand-made
      #     invoice Stacks is not tracking, and so did not refresh).
      # Attach every payer's invoice before relying on a "yes".
      #
      # Costs one QuickBooks read per attached invoice. Call it once per run
      # or page and reuse the answer; do not call it per ledger row.
      def collected?(invoice_pass:)
        run = refresh!(invoice_pass: invoice_pass)
        if run.failed.any?
          raise RefreshFailed, "Could not read the QuickBooks invoice on InvoiceTracker " \
                               "#{run.failed.map(&:id).join(', ')}; refusing to say whether " \
                               "#{invoice_pass.invoice_month}'s management fee was collected"
        end

        # A fresh pass: refresh! may have detached a tracker.
        InvoicePass.find(invoice_pass.id).management_fee_collected?
      end

      private

      def assert_no_invoice!(invoice_tracker)
        return if invoice_tracker.qbo_invoice_id.blank?
        raise PushFailed, "InvoiceTracker #{invoice_tracker.id} already has QuickBooks invoice " \
                          "#{invoice_tracker.qbo_invoice_id}. Delete it in QuickBooks, or detach it, before " \
                          "creating another."
      end

      # One QuickBooks READ: every invoice for this customer dated in the pass
      # month. Any of them stops the push -- including a voided one, which a
      # person should look at rather than Stacks guess about.
      def invoices_already_in_quickbooks(qbo_account, customer, pass, payer)
        customer_id = customer.id.to_s
        unless customer_id.match?(/\A\d+\z/)
          raise Misconfigured, "#{payer.name}'s QuickBooks customer id (#{customer_id.inspect}) is not numeric"
        end
        first_day = pass.start_of_month
        last_day = first_day.end_of_month

        service = Quickbooks::Service::Invoice.new
        service.company_id = qbo_account.realm_id
        service.access_token = qbo_account.make_and_refresh_qbo_access_token
        found = service.query(
          "SELECT * FROM Invoice WHERE CustomerRef = '#{customer_id}' " \
          "AND TxnDate >= '#{first_day.iso8601}' AND TxnDate <= '#{last_day.iso8601}'",
          per_page: 100,
        )
        Array(found&.entries)
      end

      # Always raises AlreadyInvoiced. First it records the invoices QuickBooks
      # already holds as mirror rows on garden3d's account, so the admin can
      # attach the right one from the tracker's edit page: garden3d has no
      # invoice mirror of its own, and refresh! only re-reads ATTACHED
      # invoices, so nothing else would ever put them in that dropdown.
      #
      # Must run outside any transaction, or the raise undoes the rows.
      def refuse_already_invoiced!(qbo_account, existing, pass, payer)
        listed = existing.map { |invoice| "#{invoice.id} (total #{invoice.total.to_f})" }.join(", ")
        refusal = "#{qbo_account.enterprise.name}'s QuickBooks already holds #{existing.size} invoice(s) for " \
                  "#{payer.name} dated in #{pass.invoice_month}: #{listed}. Stacks will not create another."

        begin
          existing.each do |invoice|
            # Same shape push_invoice! stores. An existing row is brought up
            # to date; an attached one stays attached.
            row = QboInvoice.find_or_initialize_by(qbo_id: invoice.id.to_s, qbo_account: qbo_account)
            row.data = invoice.as_json
            row.save!
          end
        rescue ActiveRecord::ActiveRecordError => e
          raise AlreadyInvoiced, "#{refusal} Stacks could not record them for attaching (#{e.message}); " \
                                 "try again."
        end

        raise AlreadyInvoiced, "#{refusal} They are now listed on the tracker's edit page: attach the right " \
                               "one there."
      end

      # The payer is the enterprise the tracker's Forecast client is internal to.
      def payer_for!(invoice_tracker)
        payer = Enterprise.billed_by_garden3d
          .joins(:enterprise_forecast_clients)
          .find_by(enterprise_forecast_clients: { forecast_client_id: invoice_tracker.forecast_client_id })
        if payer.nil?
          raise Misconfigured, "InvoiceTracker #{invoice_tracker.id} is not on the internal Forecast client of " \
                               "an enterprise #{Enterprise::GARDEN3D_NAME} bills"
        end
        payer
      end

      def managerial_services_item!(qbo_account)
        items, _default_item = qbo_account.fetch_all_items
        item = items.find { |candidate| candidate.fully_qualified_name == ITEM_NAME }
        if item.nil?
          raise Misconfigured, "#{qbo_account.enterprise.name}'s QuickBooks has no active item named " \
                               "\"#{ITEM_NAME}\". Restore it; Stacks will not fall back to another item."
        end
        item
      end

      def net_15_term!(qbo_account)
        due_days = Stacks::System.singleton_class::DEFAULT_PAYMENT_TERM
        term = qbo_account.fetch_all_terms.find { |candidate| candidate.due_days == due_days }
        if term.nil?
          raise Misconfigured, "#{qbo_account.enterprise.name}'s QuickBooks has no payment term due in " \
                               "#{due_days} days"
        end
        term
      end

      # By stored id, never by name: the Enterprise, Forecast client and
      # QuickBooks customer names all differ, so a name match would miss.
      # Stacks never creates a customer.
      def customer_for!(payer, qbo_account)
        stored_id = payer.g3d_qbo_customer_id.to_s
        customer = qbo_account.fetch_all_customers.find { |candidate| candidate.id.to_s == stored_id }
        if customer.nil?
          raise Misconfigured, "#{payer.name}'s stored garden3d QuickBooks customer id (#{stored_id}) is not " \
                               "an active customer. Correct it on the enterprise's edit page."
        end
        customer
      end

      def create_draft!(qbo_account, pass, customer, item, term)
        invoice = Quickbooks::Model::Invoice.new
        invoice.customer_id = customer.id
        invoice.private_note = pass.invoice_month
        invoice.bill_email = customer.primary_email_address if customer.primary_email_address.present?
        invoice.sales_term_ref = Quickbooks::Model::BaseReference.new(term.name, value: term.id)
        invoice.txn_date = pass.start_of_month.end_of_month

        line = Quickbooks::Model::InvoiceLineItem.new
        line.description = LINE_DESCRIPTION
        line.amount = ZERO
        line.sales_item! do |detail|
          detail.unit_price = ZERO
          detail.quantity = 1
          detail.item_id = item.id
        end
        invoice.line_items << line

        service = Quickbooks::Service::Invoice.new
        service.company_id = qbo_account.realm_id
        service.access_token = qbo_account.make_and_refresh_qbo_access_token
        created = service.create(invoice)
        if created.nil? || created.id.blank?
          raise PushFailed, "QuickBooks did not create the management fee invoice for #{pass.invoice_month}. " \
                            "Trying again is safe: Stacks checks QuickBooks for an existing invoice first."
        end
        created
      end
    end
  end
end
