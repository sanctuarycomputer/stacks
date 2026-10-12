module Mso
  # garden3d's management fee invoices: one InvoiceTracker per paying company
  # on garden3d's invoice pass, and one $0.00 draft invoice per tracker in
  # garden3d's QuickBooks. Finance sets the amount in QuickBooks and sends the
  # invoice; Stacks never writes an amount and never sends one.
  #
  # NOTHING HERE WRITES TO QUICKBOOKS UNATTENDED. ensure_trackers!,
  # ensure_month! and ensure_previous_month! touch the database only. push_invoice! and
  # create_drafts! write to QuickBooks and are reached only from an admin's
  # click (app/admin/invoice_passes.rb, app/admin/invoice_trackers.rb). Do not
  # call either from a rake task, a job or Stacks::Automator.
  class ManagementFeeInvoices
    class Error < StandardError; end
    class WrongPass < Error; end
    class Misconfigured < Error; end
    class PushFailed < Error; end
    class NotDraftable < Error; end
    class LegacyPass < Error; end
    class AlreadyInvoiced < Error; end
    class RefreshFailed < Error; end

    LINE_DESCRIPTION = "Management fee"
    # Resolved by name in garden3d's QuickBooks. The QBO default item
    # "Services" posts to the same income account, so falling back to it would
    # work and be wrong; a missing item raises instead.
    ITEM_NAME = "Managerial Services"
    ZERO = BigDecimal("0")

    # The first month Stacks drafts management fee invoices for: the billing
    # month of August 2026, the owner's decision. Every earlier month with a
    # fee was invoiced by hand in QuickBooks (account 4100 is non-zero from
    # 2024-01), so a draft there would be a second invoice. Earlier months can
    # still have their existing invoices ATTACHED; see ensure_month!.
    #
    # August, September and October 2026 were ALSO invoiced by hand, before
    # this shipped. They are draftable all the same: push_invoice!'s
    # pre-flight finds each existing invoice in QuickBooks, refuses to make a
    # second, and lists it on the tracker's edit page to be attached.
    MANAGEMENT_FEE_START = Date.new(2026, 8, 1)

    # How far back the nightly run looks for a month with no pass. It bounds
    # the work of one run; a month older than this is opened by an admin.
    CATCH_UP_MONTHS = 12

    DraftRun = Struct.new(:created, :already_drafted, :failed, keyword_init: true)
    RefreshRun = Struct.new(:attempted, :succeeded, :detached, :failed, keyword_init: true)

    class << self
      # One tracker per management-fee payer on garden3d's pass. Idempotent,
      # and safe to run twice at once. Database only: no QuickBooks call of
      # any kind.
      def ensure_trackers!(invoice_pass:)
        assert_management_fee_pass!(invoice_pass)
        assert_schema_ready!
        qbo_account = issuer_qbo_account(invoice_pass)

        payers = Enterprise.management_fee_payers.order(:id).to_a
        raise Misconfigured, "No enterprise is flagged as a management fee payer" if payers.empty?

        # Resolve every payer before writing anything, so one misconfigured
        # payer leaves no half-made set of trackers behind.
        planned = payers.map { |payer| [payer, internal_client_ids!(payer)] }

        ActiveRecord::Base.transaction do
          planned.map do |_payer, client_ids|
            # A payer can have several internal Forecast clients. Reuse a
            # tracker on any of them, so remapping clients never doubles up.
            find_tracker(invoice_pass, client_ids) || create_or_find_tracker!(invoice_pass, client_ids, qbo_account)
          end
        end
      end

      # The trackers `payer` has on this pass: those on any of its internal
      # Forecast clients. THE payer -> tracker mapping; ensure_trackers! and
      # InvoicePass#management_fee_collected? both go through it. A relation,
      # empty when the payer has no internal client. Database only.
      def payer_trackers(invoice_pass:, payer:)
        trackers_on(invoice_pass, internal_client_ids(payer))
      end

      # May Stacks create drafts on this pass at all?
      def draftable?(invoice_pass)
        invoice_pass.management_fee? &&
          invoice_pass.start_of_month >= MANAGEMENT_FEE_START &&
          !invoice_pass.legacy_forecast_trackers?
      end

      # Creates the $0.00 draft for one tracker in garden3d's QuickBooks and
      # attaches it. WRITES TO QUICKBOOKS. Raises on every failure; it never
      # returns without having created the invoice.
      #
      # Do not call inside a database transaction: a customer created here is
      # recorded straight away so that a later failure cannot lose its id.
      def push_invoice!(invoice_tracker:)
        pass = invoice_tracker.invoice_pass
        assert_management_fee_pass!(pass)
        assert_schema_ready!
        assert_draftable!(pass)
        assert_no_invoice!(invoice_tracker)

        qbo_account = invoice_tracker.qbo_account
        unless qbo_account.enterprise_id == pass.enterprise_id
          raise Misconfigured, "InvoiceTracker #{invoice_tracker.id} is bound to a QuickBooks account that is " \
                               "not #{pass.enterprise.name}'s"
        end

        payer = payer_for!(invoice_tracker)
        item = managerial_services_item!(qbo_account)
        term = net_15_term!(qbo_account)
        customer = resolve_customer!(payer, qbo_account)

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

      # The admin's one click: makes sure the pass has its trackers, then
      # pushes a draft for each one that has no invoice. WRITES TO QUICKBOOKS.
      # One payer failing is reported and does not stop the others.
      def create_drafts!(invoice_pass:)
        assert_management_fee_pass!(invoice_pass)
        assert_draftable!(invoice_pass) # before ensure_trackers!, so a refusal leaves nothing behind
        run = DraftRun.new(created: [], already_drafted: [], failed: [])

        ensure_trackers!(invoice_pass: invoice_pass).each do |tracker|
          if tracker.qbo_invoice_id.present?
            run.already_drafted << tracker
            next
          end

          begin
            push_invoice!(invoice_tracker: tracker)
            run.created << tracker
          rescue StandardError => e
            run.failed << [tracker, e.message]
          end
        end

        run
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
        assert_management_fee_pass!(invoice_pass)
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
      #   - any current payer has no management fee tracker on the pass;
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

      # garden3d's pass for the month containing `date`, with one tracker per
      # payer. DATABASE ONLY -- no QuickBooks call.
      #
      # Works for ANY month, including ones before MANAGEMENT_FEE_START: a
      # month invoiced by hand needs a pass and trackers so those invoices can
      # be attached. It never makes a pass draftable; see draftable?.
      #
      # The exception: a month whose pass holds a legacy Forecast tracker
      # (garden3d's seven 2025 passes). That pass's page is rendered as it
      # always was and cannot manage fee trackers, so none are added: it raises.
      def ensure_month!(date)
        assert_schema_ready!

        month = date.to_date.beginning_of_month
        pass = InvoicePass.find_or_create_by!(enterprise: Enterprise.garden3d, start_of_month: month) do |new_pass|
          new_pass.data = {}
        end
        if pass.legacy_forecast_trackers?
          raise LegacyPass, "#{Enterprise::GARDEN3D_NAME}'s pass for #{pass.invoice_month} (InvoicePass " \
                            "#{pass.id}) holds a Forecast-driven tracker from before passes were " \
                            "per-company. Stacks leaves that pass as it is and adds no management fee " \
                            "trackers to it."
        end
        ensure_trackers!(invoice_pass: pass)
        pass
      end

      # The nightly, database-only half: makes sure garden3d has a pass, with
      # its trackers, for EVERY month from MANAGEMENT_FEE_START through last
      # month, ready for an admin to act on. Normally that is last month's
      # alone. The rest is the catch-up: a month the run missed (it was not
      # deployed yet, or it failed that night) is made the next time it runs.
      # It looks back CATCH_UP_MONTHS at most, and never before the start.
      #
      # Idempotent: a month that has its pass and trackers is left as it is.
      # A month whose pass holds a legacy Forecast tracker is stepped over,
      # as ensure_month! refuses it. Answers with last month's pass, or nil
      # when there is none to make.
      #
      # NEVER WRITES TO QUICKBOOKS, AND NEVER READS IT. Do not add a push
      # here. Creating the drafts is an explicit admin click (create_drafts!).
      def ensure_previous_month!(today: Date.today)
        # Migrations are run by hand on production, after the deploy. Until
        # then this is a no-op rather than a nightly error.
        return nil unless schema_ready?

        last_month = (today - 1.month).beginning_of_month
        # Months before the start were invoiced by hand. Do not put a pass in
        # front of an admin that invites drafting them.
        month = [MANAGEMENT_FEE_START, last_month - (CATCH_UP_MONTHS - 1).months].max

        pass = nil
        while month <= last_month
          pass =
            begin
              ensure_month!(month)
            rescue LegacyPass
              nil
            end
          month = month.next_month
        end
        pass
      end

      private

      def schema_ready?
        Enterprise.column_names.include?("management_fee_payer")
      end

      # Migrations are run by hand on production, after the deploy.
      def assert_schema_ready!
        return if schema_ready?
        raise Misconfigured, "The management fee columns are not on this database yet. " \
                             "Run migration 20261013000001 first."
      end

      def assert_management_fee_pass!(invoice_pass)
        return if invoice_pass.management_fee?
        raise WrongPass, "Management fee invoices live on #{Enterprise::GARDEN3D_NAME}'s pass; " \
                         "InvoicePass #{invoice_pass.id} belongs to #{invoice_pass.enterprise.name}"
      end

      # Ordered query, not enterprise.qbo_account: has_one is unordered.
      def issuer_qbo_account(invoice_pass)
        qbo_account = QboAccount.where(enterprise_id: invoice_pass.enterprise_id).order(:id).first
        raise Misconfigured, "#{invoice_pass.enterprise.name} has no connected QboAccount" if qbo_account.nil?
        qbo_account
      end

      # Queried fresh, lowest Forecast id first, so the choice is the same on
      # every run and never comes from a stale association cache.
      def internal_client_ids(payer)
        EnterpriseForecastClient
          .where(enterprise_id: payer.id)
          .order(:forecast_client_id)
          .pluck(:forecast_client_id)
      end

      def internal_client_ids!(payer)
        ids = internal_client_ids(payer)
        if ids.empty?
          raise Misconfigured, "#{payer.name} is a management fee payer but has no internal Forecast client " \
                               "to hang its invoice tracker on"
        end
        ids
      end

      def trackers_on(invoice_pass, client_ids)
        InvoiceTracker.where(invoice_pass_id: invoice_pass.id, forecast_client_id: client_ids)
      end

      def find_tracker(invoice_pass, client_ids)
        trackers_on(invoice_pass, client_ids).order(:id).first
      end

      # Two first-time calls at once (a double click on Create drafts, or the
      # click racing the nightly run) both find no tracker and both insert; the
      # unique index on (forecast_client_id, invoice_pass_id) refuses the
      # second. The row that won is the other caller's tracker: use it. The
      # savepoint keeps the surrounding transaction usable after the refusal.
      def create_or_find_tracker!(invoice_pass, client_ids, qbo_account)
        InvoiceTracker.transaction(requires_new: true) do
          InvoiceTracker.create!(
            invoice_pass: invoice_pass,
            forecast_client_id: client_ids.first,
            qbo_account: qbo_account,
          )
        end
      rescue ActiveRecord::RecordNotUnique
        find_tracker(invoice_pass, client_ids) || raise
      end

      def assert_draftable!(invoice_pass)
        return if draftable?(invoice_pass)

        reason =
          if invoice_pass.start_of_month < MANAGEMENT_FEE_START
            "Stacks drafts management fee invoices from #{MANAGEMENT_FEE_START.strftime('%B %Y')} onward; " \
              "#{invoice_pass.invoice_month} was invoiced by hand"
          else
            "#{invoice_pass.invoice_month}'s pass holds a Forecast-driven tracker from before passes were " \
              "per-company"
          end
        # No "attach it from the edit page" on its own: that dropdown lists
        # mirror rows, and for a month Stacks never drafts nothing makes them
        # unless garden3d's invoices are synced by hand.
        raise NotDraftable, "#{reason}. Stacks will not create a draft. To attach the existing QuickBooks " \
                            "invoice instead, garden3d's invoices must first be synced into Stacks " \
                            "(QboAccount#sync_all_invoices!, from the console); it is then listed on the " \
                            "tracker's edit page."
      end

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
        payer = Enterprise
          .joins(:enterprise_forecast_clients)
          .find_by(enterprise_forecast_clients: { forecast_client_id: invoice_tracker.forecast_client_id })
        unless payer&.management_fee_payer?
          raise Misconfigured, "InvoiceTracker #{invoice_tracker.id} does not belong to a management fee payer " \
                               "(#{payer&.name || 'its Forecast client is not internal to any enterprise'})"
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
      # QuickBooks customer names all differ, so a name match would miss and
      # then create a duplicate customer that Finance invoices for real.
      def resolve_customer!(payer, qbo_account)
        stored_id = payer.g3d_qbo_customer_id.presence
        active_customers = qbo_account.fetch_all_customers

        if stored_id
          customer = active_customers.find { |candidate| candidate.id.to_s == stored_id.to_s }
          if customer.nil?
            raise Misconfigured, "#{payer.name}'s stored garden3d QuickBooks customer id (#{stored_id}) is not " \
                                 "an active customer. Correct the id; Stacks never creates a customer while " \
                                 "one is stored."
          end
          return customer
        end

        # No id stored. If an active customer already carries exactly this
        # name, an earlier create probably succeeded and its id was lost.
        # Do not create a second, and do not adopt this one on a name match.
        same_name = active_customers.select do |candidate|
          [candidate.display_name, candidate.company_name, candidate.fully_qualified_name]
            .compact.any? { |name| name.strip.casecmp?(payer.name.strip) }
        end
        if same_name.any?
          raise Misconfigured, "#{payer.name} has no stored garden3d QuickBooks customer id, but an active " \
                               "customer already has that name (id #{same_name.map(&:id).join(', ')}). If it " \
                               "is the right one, store its id on the enterprise (g3d_qbo_customer_id) and " \
                               "try again. Stacks will not create a second customer or adopt one by name."
        end

        customer = Quickbooks::Model::Customer.new
        customer.display_name = payer.name
        customer.company_name = payer.name

        service = Quickbooks::Service::Customer.new
        service.company_id = qbo_account.realm_id
        service.access_token = qbo_account.make_and_refresh_qbo_access_token
        begin
          created = service.create(customer)
        rescue Quickbooks::IntuitRequestException => e
          raise unless e.code.to_s == "6240" || e.message.to_s.match?(/duplicate name/i)
          raise Misconfigured, "QuickBooks refused to create a customer named \"#{payer.name}\": a customer, " \
                               "vendor or employee already has that name (it may be inactive). Find it in " \
                               "QuickBooks; if it is this company's customer record, store its id on the " \
                               "enterprise (g3d_qbo_customer_id)."
        end
        if created.nil? || created.id.blank?
          raise PushFailed, "QuickBooks did not create a customer for #{payer.name}"
        end

        # Straight to the column, before anything else can fail: losing this
        # id would mean a refused push on the next attempt.
        payer.update_columns(g3d_qbo_customer_id: created.id.to_s)
        created
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
