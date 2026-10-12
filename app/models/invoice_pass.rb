class InvoicePass < ApplicationRecord
  # A pass belongs to the enterprise that ISSUES its invoices, not to the
  # clients being billed. A tracker lives on the pass of its qbo_account's
  # enterprise. Before this was modelled, garden3d's invoices rode on
  # Sanctuary's pass (7 mixed passes, 2025-06 .. 2025-12).
  belongs_to :enterprise
  has_many :invoice_trackers
  # One per run of the month's MSO compensation; at most one is current.
  # Only garden3d's passes ever have any.
  has_many :mso_snapshots

  class UnsupportedIssuer < StandardError; end

  # What a tracker on this pass IS depends on who issues the pass:
  #
  #   Sanctuary  -> Forecast-driven (blueprint, contributor payouts)
  #   garden3d   -> a management fee invoice to each paying company
  #   otherwise  -> unsupported
  #
  # There is no column for this; the enterprise decides.
  def forecast?
    enterprise == Enterprise.sanctuary
  end

  # Checks forecast? first so a Sanctuary pass -- nearly every pass -- never
  # depends on a garden3d row existing.
  def management_fee?
    return false if forecast?
    enterprise == Enterprise.garden3d
  end

  # For anything that ACTS on a pass. Index Space and USB Club both have
  # QuickBooks accounts, so a pass for either is constructible; treating it as
  # one of the two known kinds is how the wrong company gets invoiced.
  def invoicing_kind
    return :forecast if forecast?
    return :management_fee if management_fee?

    raise UnsupportedIssuer, "InvoicePass #{id} belongs to #{enterprise&.name || 'no enterprise'}. Only " \
                             "#{Enterprise::SANCTUARY_NAME} (Forecast invoicing) and " \
                             "#{Enterprise::GARDEN3D_NAME} (management fee) issue invoices."
  end

  # garden3d's 2025 passes each hold one Forecast-driven tracker (a blueprint,
  # accepted payouts) from before passes were per-enterprise. A pass holding
  # one is left exactly as it was: Stacks never drafts on it. Always a fresh
  # query, so it cannot read a stale association.
  def legacy_forecast_trackers?
    InvoiceTracker.where(invoice_pass_id: id).where.not(blueprint: nil).exists?
  end

  # Has garden3d been paid the management fee it charged for this month?
  # THE PURE RULE, over the invoice mirrors AS STORED. It makes no QuickBooks
  # call, so it is only as right as the mirrors are fresh -- and a mirror is
  # stored as an unsent $0.00 draft and not updated until someone refreshes.
  #
  #   To decide whether anyone is PAID, call
  #   Mso::ManagementFeeInvoices.collected?(invoice_pass:) instead. It
  #   refreshes from QuickBooks first and raises if it cannot.
  #
  # An invoice is CHARGED when it was sent OR its total is above zero. It is
  # ignored only when it is unsent and zero (the untouched draft Stacks makes
  # for every payer), or voided. Collected = at least one charged invoice,
  # and every charged invoice has a total above zero and nothing outstanding.
  #
  # That is only a "yes" when Stacks can vouch for the whole month, so the
  # rule FAILS CLOSED on anything it cannot see. All of these are unknown,
  # and unknown is not collected:
  #
  # - A current payer (Enterprise.management_fee_payers) with NO management
  #   fee tracker on this pass: flagged after the pass was made, or its
  #   tracker was deleted. The payer -> tracker mapping is the one
  #   ensure_trackers! uses (Mso::ManagementFeeInvoices.payer_trackers).
  # - A management fee tracker with NO invoice attached. Stacks cannot see
  #   whether that payer was charged -- the pre-flight refuses to draft when
  #   Finance already invoiced by hand, and that invoice stays invisible here
  #   until someone attaches it. (An attached, unsent, zero draft is the
  #   "nobody was charged" case.)
  # - An attached invoice whose stored txn_date is outside this pass's month,
  #   or missing, or unreadable: it is some other month's invoice, and this
  #   month's own may be unpaid. Checked on every attached invoice, even a
  #   draft or a voided one.
  # - An invoice in garden3d's mirror billed to a payer's stored garden3d
  #   customer id, dated in this pass's month, that is NOT attached to a
  #   tracker on this pass: a second or hand-made invoice Stacks is not
  #   tracking. Nothing refreshes an unattached mirror, so even one stored as
  #   paid, or as an untouched draft, blocks. The exception is one stored as
  #   voided (below): voiding is final, so a stale copy cannot hide a charge.
  #   An invoice to anyone else, or dated in another month, or in another
  #   company's books, is not this pass's business.
  #
  # And on the invoices it can see:
  #
  # - An invoice with an amount that was never emailed still posts to account
  #   4100 and raises the cap, so it is a charge.
  # - A sent $0.00 invoice is a charge with no total, so it is NOT collected.
  #   QboInvoice#status reads it as :paid, which is why this does not use it.
  # - Voided means the note says so AND total and balance are both zero, as
  #   QuickBooks leaves a voided invoice. A note alone ("replaces voided #12")
  #   never hides an amount.
  # - No stored data, or an unreadable amount, is unknown: not collected.
  def management_fee_collected?
    unless management_fee?
      raise "management_fee_collected? only applies to #{Enterprise::GARDEN3D_NAME}'s passes " \
            "(this pass belongs to #{enterprise.name})"
    end

    own_account_ids = QboAccount.where(enterprise_id: enterprise_id).pluck(:id)
    payers = Enterprise.management_fee_payers.order(:id).to_a
    charged = []
    attached = []

    # Every current payer needs a fee tracker here, or its invoice is unseen.
    # (A legacy Forecast tracker, which has a blueprint, is not one.)
    payers.each do |payer|
      fee_trackers = Mso::ManagementFeeInvoices.payer_trackers(invoice_pass: self, payer: payer)
      return false unless fee_trackers.where(blueprint: nil).exists?
    end

    # Fresh queries throughout, by the (account, id) pair: never the cached
    # association, and never the qbo_invoice association.
    InvoiceTracker.where(invoice_pass_id: id).order(:id).each do |tracker|
      if tracker.qbo_invoice_id.blank?
        # Nothing attached. On a fee tracker that is unknown, so fail closed.
        # A legacy Forecast tracker (it has a blueprint) is not a fee invoice.
        return false if tracker.blueprint.nil?
        next
      end

      unless own_account_ids.include?(tracker.qbo_account_id)
        raise "InvoiceTracker #{tracker.id} on this pass points at QuickBooks account " \
              "#{tracker.qbo_account_id}, which is not #{enterprise.name}'s"
      end

      mirror = QboInvoice.find_by(qbo_account_id: tracker.qbo_account_id, qbo_id: tracker.qbo_invoice_id)
      stored = mirror&.read_attribute(:data)
      return false if stored.blank?

      # Another month's invoice, or one with no readable date: unknown.
      dated = stored_date(stored["txn_date"])
      return false if dated.nil? || dated.beginning_of_month != start_of_month
      attached << [tracker.qbo_account_id, tracker.qbo_invoice_id]

      total = stored_amount(stored["total"])
      balance = stored_amount(stored["balance"])
      return false if total.nil? || balance.nil?

      next if stored_as_voided?(stored)

      sent = stored["email_status"] == "EmailSent"
      next unless sent || total.positive? # unsent and zero: nobody was charged

      charged << [total, balance]
    end

    return false if untracked_payer_invoice?(own_account_ids, payers, attached)
    return false if charged.empty?
    charged.all? { |total, balance| total.positive? && balance.zero? }
  end

  def complete?
    completed_at.present?
  end

  def allows_payment_splits?
    start_of_month >= Stacks::System.singleton_class::NEW_DEAL_START_AT
  end

  def statuses
    if (data || {})["reminder_passes"].present? && latest_reminder_pass.any?
      :missing_hours
    else
      status = invoice_trackers.map(&:status)
      status.inject(Hash.new(0)) { |h, e| h[e] += 1 ; h }
    end
  end

  def payout_statuses
    return [] unless allows_payment_splits?
    # compact: a management fee tracker has no payout status at all.
    status = invoice_trackers.map(&:contributor_payouts_status).compact
    status.inject(Hash.new(0)) { |h, e| h[e] += 1 ; h }
  end

  def value
    invoice_trackers.map(&:value).compact.reduce(&:+)
  end

  def surplus
    invoice_trackers.map(&:surplus).compact.reduce(&:+)
  end

  def balance
    invoice_trackers.map(&:balance).compact.reduce(&:+)
  end

  def make_trackers!
    # Everything below is Forecast-driven invoicing, which only Sanctuary does.
    # Every non-internal client bills through Sanctuary, so on any other
    # enterprise's pass there is nothing for this to create.
    unless enterprise == Enterprise.sanctuary
      raise "make_trackers! is Forecast invoicing and only runs on #{Enterprise::SANCTUARY_NAME}'s passes (this pass belongs to #{enterprise.name})"
    end
    return if statuses == :missing_hours

    qa = enterprise.qbo_account
    raise "#{enterprise.name} has no connected QboAccount" if qa.nil?

    # Internal clients (mapped via enterprise_forecast_clients) generate pay
    # stubs against their enterprise's pay cycles instead of being invoiced.
    # Skip them here so they never enter the InvoiceTracker pipeline.
    clients_served.reject(&:is_internal?).each do |c|
      InvoiceTracker.find_or_create_by!(
        forecast_client_id: c.forecast_id,
        invoice_pass: self,
      ) do |t|
        t.qbo_account = qa
      end
    end
  end

  def clients_served
    [
      *Stacks::System.clients_served_since(start_of_month, start_of_month.end_of_month),
      *RecurringCharge.includes(:forecast_client).all.map(&:forecast_client).compact.uniq
    ]
  end

  def period
    Stacks::Period.new(invoice_month, start_of_month, start_of_month.end_of_month)
  end

  def invoice_month
    start_of_month.strftime("%B %Y")
  end

  def latest_reminder_pass_date
    (data || {})["reminder_passes"].keys.map{|ds| DateTime.parse(ds)}.max
  end

  def latest_reminder_pass
    return nil if latest_reminder_pass_date.nil?
    (data || {})["reminder_passes"][latest_reminder_pass_date.iso8601]
  end

  ## TODO: Remove the below when we move away from automator
  def latest_generator_pass_date
    (data || {})["generator_passes"].keys.map{|ds| DateTime.parse(ds)}.max
  end

  def latest_generator_pass
    return nil if latest_generator_pass_date.nil?
    (data || {})["generator_passes"][latest_generator_pass_date.iso8601]
  end

  private

  # The mirror stores amounts as Strings ("130000.0"). nil when unparseable.
  def stored_amount(value)
    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  # The mirror stores what Quickbooks::Model::Invoice#as_json gives: the
  # transaction date as an ISO String ("2026-10-31") under "txn_date". nil
  # when missing or unparseable.
  def stored_date(value)
    return nil unless value.is_a?(String)
    Date.iso8601(value)
  rescue ArgumentError
    nil
  end

  # As QuickBooks leaves a voided invoice: the note says so AND total and
  # balance are both zero.
  def stored_as_voided?(stored)
    total = stored_amount(stored["total"])
    balance = stored_amount(stored["balance"])
    return false if total.nil? || balance.nil?
    stored["private_note"].to_s.downcase.include?("voided") && total.zero? && balance.zero?
  end

  # Does garden3d's mirror hold an invoice to a payer, dated in this month,
  # that no tracker on this pass has attached? Stored rows only, read in SQL
  # and through pluck: never QboInvoice#data, which can call QuickBooks.
  def untracked_payer_invoice?(own_account_ids, payers, attached)
    customer_ids = payers.map(&:g3d_qbo_customer_id).reject(&:blank?).map(&:to_s)
    return false if own_account_ids.empty? || customer_ids.empty?

    QboInvoice
      .where(qbo_account_id: own_account_ids)
      .where("qbo_invoices.data->'customer_ref'->>'value' IN (?)", customer_ids)
      .where("qbo_invoices.data->>'txn_date' >= ? AND qbo_invoices.data->>'txn_date' < ?",
             start_of_month.iso8601, start_of_month.next_month.iso8601)
      .pluck(:qbo_account_id, :qbo_id, :data)
      .any? do |account_id, qbo_id, stored|
        !attached.include?([account_id, qbo_id]) && !stored_as_voided?(stored)
      end
  end
end
