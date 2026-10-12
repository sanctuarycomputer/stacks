class InvoicePass < ApplicationRecord
  # A pass belongs to the enterprise that ISSUES its invoices, not to the
  # clients being billed. A tracker lives on the pass of its qbo_account's
  # enterprise. Before this was modelled, garden3d's invoices rode on
  # Sanctuary's pass (7 mixed passes, 2025-06 .. 2025-12).
  belongs_to :enterprise
  has_many :invoice_trackers

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
  # - An invoice with an amount that was never emailed still posts to account
  #   4100 and raises the cap, so it is a charge.
  # - A sent $0.00 invoice is a charge with no total, so it is NOT collected.
  #   QboInvoice#status reads it as :paid, which is why this does not use it.
  # - No stored data, or an unreadable amount, is unknown: not collected.
  def management_fee_collected?
    unless management_fee?
      raise "management_fee_collected? only applies to #{Enterprise::GARDEN3D_NAME}'s passes " \
            "(this pass belongs to #{enterprise.name})"
    end

    own_account_ids = QboAccount.where(enterprise_id: enterprise_id).pluck(:id)
    charged = []

    # Fresh queries throughout, by the (account, id) pair: never the cached
    # association, and never the qbo_invoice association.
    InvoiceTracker.where(invoice_pass_id: id).where.not(qbo_invoice_id: nil).order(:id).each do |tracker|
      unless own_account_ids.include?(tracker.qbo_account_id)
        raise "InvoiceTracker #{tracker.id} on this pass points at QuickBooks account " \
              "#{tracker.qbo_account_id}, which is not #{enterprise.name}'s"
      end

      mirror = QboInvoice.find_by(qbo_account_id: tracker.qbo_account_id, qbo_id: tracker.qbo_invoice_id)
      stored = mirror&.read_attribute(:data)
      return false if stored.blank?

      next if stored["private_note"].to_s.downcase.include?("voided")

      total = stored_amount(stored["total"])
      balance = stored_amount(stored["balance"])
      return false if total.nil? || balance.nil?

      sent = stored["email_status"] == "EmailSent"
      next unless sent || total.positive? # unsent and zero: nobody was charged

      charged << [total, balance]
    end

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
end
