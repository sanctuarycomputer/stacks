class Contributor < ApplicationRecord
  default_scope -> { joins(:forecast_person).order("forecast_people.email ASC") }

  belongs_to :forecast_person, class_name: "ForecastPerson", foreign_key: "forecast_person_id", primary_key: "forecast_id"
  belongs_to :deel_person, class_name: "DeelPerson", foreign_key: "deel_person_id", primary_key: "deel_id", optional: true

  has_many :contributor_qbo_vendors, dependent: :destroy
  has_many :qbo_vendors, through: :contributor_qbo_vendors
  accepts_nested_attributes_for :contributor_qbo_vendors, allow_destroy: true,
    reject_if: ->(attrs) { attrs[:qbo_vendor_id].blank? }

  # Every contributor gets a Ledger row for every enterprise so reimbursements
  # / pay stubs / etc. against any enterprise work the moment the contributor
  # exists — no manual setup, no waiting on the daily cron.
  after_create :ensure_ledgers_for_all_enterprises!

  def ensure_ledgers_for_all_enterprises!
    Ledger.ensure_for_contributor!(self)
  end

  # Idempotently creates a Contributor row for every active ForecastPerson
  # that doesn't already have one. Historically Contributors were created
  # lazily — only when a person first landed on an invoice / pay cycle —
  # which meant admins and contractors who hadn't been invoiced yet had
  # no Contributor → no Ledger anywhere, and couldn't file reimbursements,
  # accept pay stubs, etc. Running this from the daily task closes that
  # gap.
  #
  # Archived ForecastPersons are intentionally skipped — they represent
  # off-boarded people who shouldn't accrue new ledger rows.
  #
  # Contributor.after_create cascades into Ledger.ensure_for_contributor!,
  # so each newly created Contributor immediately gets a Ledger for every
  # existing Enterprise without a second pass.
  #
  # Returns the count of Contributors created.
  def self.ensure_all_for_forecast_people!
    existing_fp_ids = unscoped.pluck(:forecast_person_id).to_set
    missing = ForecastPerson.active.where.not(forecast_id: existing_fp_ids)
    created = 0
    missing.find_each do |fp|
      Contributor.create!(forecast_person: fp)
      created += 1
    end
    created
  end

  # Looks up this contributor's QboVendor record within a specific QBO account.
  # Returns nil when no mapping exists for that account. This is the canonical
  # vendor lookup; SyncsAsQboBill#sync_qbo_bill! uses it to route bills to
  # the correct per-enterprise QBO.
  def qbo_vendor_for(qbo_account)
    return nil if qbo_account.nil?
    qbo_vendors.find_by(qbo_account_id: qbo_account.id)
  end

  has_many :ledgers

  has_many :reimbursements, through: :ledgers
  has_many :contributor_payouts, through: :ledgers
  has_many :trueups, through: :ledgers
  has_many :profit_shares, through: :ledgers
  has_many :contributor_adjustments, through: :ledgers
  has_many :deel_invoice_adjustments, through: :ledgers
  has_many :pay_stubs, through: :ledgers
  has_many :recurring_ledger_adjustments, through: :ledgers
  has_many :ledger_withdrawal_requests, through: :ledgers

  # Each *_with_deleted method below is memoized per-instance. The first call
  # fires a query; subsequent calls return the cached array.
  #
  # `preload_for_ledger_view!` warms all six caches at once with the heavier
  # eager-loads the ledger UI needs. Call it from the admin show action to
  # avoid lazy queries inside `all_items_grouped_by_month`.

  # Preload chains used by `payable?` on each item type. Without these, the
  # `new_deal_balance` walk fires hundreds of N+1 queries (invoice_pass per
  # ContributorPayout, pay_cycle.pay_stubs per PayStub, periodic_report per
  # ProfitShare). Cuts AdminUser show page DB time from ~80s to <2s.
  def contributor_payouts_with_deleted
    @_contributor_payouts_with_deleted ||=
      ContributorPayout.with_deleted
        .joins(:ledger)
        .includes(invoice_tracker: { invoice_pass: {}, contributor_payouts: [] })
        .where(ledgers: { contributor_id: id }).to_a
  end

  def contributor_adjustments_with_deleted
    @_contributor_adjustments_with_deleted ||=
      preload_qbo_invoices_for(
        ContributorAdjustment.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id }).to_a,
      )
  end

  def trueups_with_deleted
    @_trueups_with_deleted ||=
      Trueup.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id }).to_a
  end

  def reimbursements_with_deleted
    @_reimbursements_with_deleted ||=
      Reimbursement.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id }).to_a
  end

  def profit_shares_with_deleted
    @_profit_shares_with_deleted ||=
      ProfitShare.with_deleted
        .joins(:ledger)
        .includes(:periodic_report)
        .where(ledgers: { contributor_id: id }).to_a
  end

  def deel_invoice_adjustments_with_deleted
    @_deel_invoice_adjustments_with_deleted ||=
      DeelInvoiceAdjustment.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id }).to_a
  end

  def pay_stubs_with_deleted
    @_pay_stubs_with_deleted ||=
      PayStub.with_deleted
        .joins(:ledger)
        .includes(pay_cycle: :pay_stubs)
        .where(ledgers: { contributor_id: id }).to_a
  end

  # Withdrawal requests are not soft-deletable — `_with_deleted` is a naming
  # convention here so the splice into all_items_grouped_by_month reads
  # uniformly with the other ledger-item collections.
  def ledger_withdrawal_requests_with_deleted
    @_ledger_withdrawal_requests_with_deleted ||=
      LedgerWithdrawalRequest
        .joins(:ledger)
        .includes(:bills, :cancelled_by)
        .where(ledgers: { contributor_id: id }).to_a
  end

  private

  # Resolves the composite-key QboInvoice lookup that `payable?` does on
  # ContributorAdjustment / PayStub. Bulk-fetches every referenced
  # (qbo_account_id, qbo_id) pair in one query and assigns it onto the AR
  # association target so subsequent `.qbo_invoice` calls hit the in-memory
  # cache (see HasQboInvoiceViaCompositeKey#qbo_invoice).
  def preload_qbo_invoices_for(items)
    pairs = items.map { |i| [i.qbo_account_id, i.qbo_invoice_id] }
      .reject { |qa_id, qbo_id| qa_id.blank? || qbo_id.blank? }
      .uniq
    return items if pairs.empty?

    qa_ids = pairs.map(&:first).uniq
    qbo_ids = pairs.map(&:last).uniq
    invoices = QboInvoice
      .where(qbo_account_id: qa_ids, qbo_id: qbo_ids)
      .index_by { |inv| [inv.qbo_account_id, inv.qbo_id] }

    items.each do |item|
      key = [item.qbo_account_id, item.qbo_invoice_id]
      inv = invoices[key]
      item.association(:qbo_invoice).target = inv if inv
    end
    items
  end

  public

  # Eager-loads the six *_with_deleted collections with the heavier includes
  # the ledger view body needs (so the partial doesn't trip N+1 inside the
  # type-switching loop). Each query also preloads `ledger` so the LedgerItem
  # concern's `delegate :contributor, to: :ledger` doesn't re-query per item;
  # we also stamp the ledger's contributor association target to `self` so
  # `item.contributor` returns this Contributor without ever touching SQL.
  def preload_for_ledger_view!
    @_contributor_payouts_with_deleted =
      ContributorPayout.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id })
        .includes(
          :ledger,
          # Preload :contributor_payouts on the invoice_tracker so
          # InvoiceTracker#contributor_payouts_status stays in-memory
          # (otherwise it fires 2 SQL queries per invoice_tracker for the
          # `.exists?` + `.where(accepted_at: nil).none?` fallback branch).
          invoice_tracker: [:invoice_pass, :forecast_client, :qbo_invoice, :contributor_payouts],
        ).to_a
    @_contributor_adjustments_with_deleted =
      ContributorAdjustment.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id })
        .includes(:ledger, :qbo_invoice).to_a
    @_trueups_with_deleted =
      Trueup.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id })
        .includes(:ledger, :invoice_pass).to_a
    @_reimbursements_with_deleted =
      Reimbursement.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id })
        .includes(:ledger).to_a
    @_profit_shares_with_deleted =
      ProfitShare.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id })
        .includes(:ledger, periodic_report: :profit_shares).to_a
    @_deel_invoice_adjustments_with_deleted =
      DeelInvoiceAdjustment.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id })
        .includes(:ledger, :deel_contract).to_a
    @_pay_stubs_with_deleted =
      PayStub.with_deleted.joins(:ledger).where(ledgers: { contributor_id: id })
        .includes(:ledger, :pay_cycle).to_a
    @_ledger_withdrawal_requests_with_deleted =
      LedgerWithdrawalRequest.joins(:ledger).where(ledgers: { contributor_id: id })
        .includes(:ledger, :bills, :cancelled_by).to_a

    # Short-circuit `item.contributor` (and any downstream delegate hop) to
    # this Contributor. All preloaded items belong to ledgers whose contributor
    # IS self, by construction of the queries above.
    [
      @_contributor_payouts_with_deleted,
      @_contributor_adjustments_with_deleted,
      @_trueups_with_deleted,
      @_reimbursements_with_deleted,
      @_profit_shares_with_deleted,
      @_deel_invoice_adjustments_with_deleted,
      @_pay_stubs_with_deleted,
      @_ledger_withdrawal_requests_with_deleted,
    ].each do |items|
      items.each do |item|
        item.ledger.association(:contributor).target = self
      end
    end

    self
  end

  # Contributors with a recent ContributorPayout OR a recent PayStub in the
  # last 3 months — both flow through the per-enterprise Ledger, so a salaried
  # team member with no contributor_payouts but a recent pay stub is still a
  # "recent contributor" for the admin index.
  scope :recent_contributors, -> {
    recent = 3.months.ago
    where(
      id: ContributorPayout.where("contributor_payouts.created_at > ?", recent).joins(:ledger).select("ledgers.contributor_id"),
    ).or(
      where(id: PayStub.where("pay_stubs.created_at > ?", recent).joins(:ledger).select("ledgers.contributor_id"))
    )
  }

  scope :forecast_email_cont, ->(value) {
    return all if value.blank?

    term = "%#{ActiveRecord::Base.sanitize_sql_like(value.to_s.strip)}%"
    where(forecast_person_id: ForecastPerson.where("email ILIKE ?", term).select(:forecast_id))
  }

  def self.ransackable_scopes(*)
    %i[forecast_email_cont]
  end

  def total_amount_paid
    d = {
      salary: 0,
      contract: contributor_payouts.sum(:amount),
      total: 0
    }

    if admin_user = forecast_person.try(:admin_user)
      ausw = admin_user.admin_user_salary_windows.all
      d = admin_user.full_time_periods.reduce({ salary: 0, contract: 0, total: 0 }) do |acc, ftp|
        next acc unless ftp.four_day? || ftp.five_day?
        ftp.started_at.upto(ftp.ended_at || Date.today).each do |date|
          days_in_month = Time.days_in_month(date.month, date.year)
          w = ausw.find{|sw| sw.start_date <= date && date <= (sw.end_date || Date.today) }
          next if w.nil?
          day_rate = w.salary / 12 / days_in_month
          acc[:salary] += day_rate
        end
        acc
      end
    end

    d[:total] = d[:salary] + d[:contract]
    d
  end

  def sync_qbo_bills!
    contributor_payouts.each do |cp|
      cp.sync_qbo_bill!
    end
    contributor_adjustments.each do |adj|
      adj.sync_qbo_bill!
    end
    profit_shares.each do |ps|
      ps.sync_qbo_bill!
    end
  end

  def display_name
    forecast_person.email
  end

  # Staff admins (`admin_user.is_admin?`) see Deel Withdrawal UI whenever this contributor has a Deel person.
  # Linked contributors (non-staff) see it when they are the ForecastPerson's admin user.
  def deel_invoice_actions_visible_to?(admin_user)
    return false unless deel_person_id.present?
    return true if admin_user.is_admin?

    forecast_person&.admin_user == admin_user
  end

  def new_deal_balance(ledger_items = all_items_grouped_by_month(false))
    ledger_items[:all].reduce({ balance: 0, unsettled: 0 }) do |acc, li|
      next acc if li.respond_to?(:deleted_at) && li.deleted_at.present?

      if li.is_a?(ContributorPayout)
        if li.payable?
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
        acc[:balance] += li.amount
      elsif li.is_a?(ProfitShare)
        if li.payable?
          acc[:balance] += li.amount
        else
          acc[:unsettled] += li.amount
        end
      elsif li.is_a?(ContributorAdjustment)
        if li.payable?
          acc[:balance] += li.amount
        else
          acc[:unsettled] += li.amount
        end
      elsif li.is_a?(PayStub)
        if li.payable?
          acc[:balance] += li.amount
        else
          acc[:unsettled] += li.amount
        end
      elsif li.is_a?(DeelInvoiceAdjustment)
        acc[:balance] -= li.amount if li.deducts_balance?
      end
      acc
    end
  end

  def self.aggregated_new_deal_balance
    all_contributor_payouts = ContributorPayout.includes(invoice_tracker: :invoice_pass).all
    all_reimbursements = Reimbursement.all
    all_trueups = Trueup.all
    all_profit_shares = ProfitShare.includes(:periodic_report).all
    all_contributor_adjustments = ContributorAdjustment.all
    all_deel_invoice_adjustments = DeelInvoiceAdjustment.all

    ledger = all_contributor_payouts.reduce({ balance: 0, unsettled: 0 }) do |acc, cp|
      next acc if cp.invoice_tracker.invoice_pass.start_of_month > Date.today
      if cp.payable?
        acc[:balance] += cp.amount
      else
        acc[:unsettled] += cp.amount
      end
      acc
    end

    ledger = all_reimbursements.reduce(ledger) do |acc, r|
      next acc if r.created_at > Date.today
      if r.accepted?
        acc[:balance] += r.amount
      else
        acc[:unsettled] += r.amount
      end
      acc
    end

    ledger = all_trueups.reduce(ledger) do |acc, tu|
      next acc if tu.payment_date > Date.today
      acc[:balance] += tu.amount
      acc
    end

    ledger = all_profit_shares.reduce(ledger) do |acc, ps|
      next acc if ps.applied_at > Date.today
      acc[:balance] += ps.amount
      acc
    end

    ledger = all_contributor_adjustments.reduce(ledger) do |acc, adj|
      next acc if adj.effective_on > Date.today
      if adj.payable?
        acc[:balance] += adj.amount
      else
        acc[:unsettled] += adj.amount
      end
      acc
    end

    ledger = all_deel_invoice_adjustments.reduce(ledger) do |acc, row|
      next acc if row.date_submitted > Date.today
      next acc unless row.deducts_balance?

      acc[:balance] -= row.amount
      acc
    end

    ledger
  end

  # Cross-enterprise aggregation. `elevated_service` is fundamentally an ALL-ENTERPRISES
  # concept — a contributor's total contribution across the company that month — so it
  # lives here, not on Ledger. Per-enterprise views should use Ledger#items_grouped_by_month
  # instead, which omits elevated_service / total_hours / partial_salary / fulltime.
  def all_items_grouped_by_month(include_salary = true, override_ledger_starts_at = nil, override_ledger_ends_at = nil)
    preloaded_contributor_payouts = contributor_payouts_with_deleted
    preloaded_reimbursements = reimbursements_with_deleted
    preloaded_trueups = trueups_with_deleted
    preloaded_profit_shares = profit_shares_with_deleted
    preloaded_adjustments = contributor_adjustments_with_deleted
    preloaded_deel_invoice_adjustments = deel_invoice_adjustments_with_deleted
    preloaded_pay_stubs = pay_stubs_with_deleted
    preloaded_withdrawal_requests = ledger_withdrawal_requests_with_deleted

    if override_ledger_ends_at.present?
      ledger_ends_at = override_ledger_ends_at
    else
      ledger_ends_at = [
        *preloaded_contributor_payouts,
        *preloaded_trueups,
        *preloaded_adjustments,
        *preloaded_deel_invoice_adjustments,
        *preloaded_pay_stubs,
        *preloaded_withdrawal_requests,
      ].reduce(Date.today) do |acc, li|
        if li.is_a?(ContributorPayout)
          acc = li.invoice_tracker.invoice_pass.start_of_month if li.invoice_tracker.invoice_pass.start_of_month > acc
        elsif li.is_a?(Reimbursement)
          acc = li.created_at if li.created_at > acc
        elsif li.is_a?(Trueup)
          acc = li.payment_date if li.payment_date > acc
        elsif li.is_a?(ProfitShare)
          acc = li.applied_at if li.applied_at > acc
        elsif li.is_a?(ContributorAdjustment)
          acc = li.effective_on if li.effective_on > acc
        elsif li.is_a?(DeelInvoiceAdjustment)
          d = li.date_submitted
          acc = d if d > acc
        elsif li.is_a?(PayStub)
          d = li.effective_on_for_display
          acc = d if d > acc
        elsif li.is_a?(LedgerWithdrawalRequest)
          d = li.effective_on_for_display
          acc = d if d && d > acc
        end
        acc
      end + 2.months
    end

    if override_ledger_starts_at.present?
      ledger_starts_at = override_ledger_starts_at
    else
      ledger_starts_at = Stacks::System.singleton_class::NEW_DEAL_START_AT
      contiguous_ftps = []
      if admin_user = forecast_person.admin_user && forecast_person.admin_user
        ledger_starts_at = admin_user.start_date
        contiguous_ftps = admin_user.contiguous_full_time_periods_until(ledger_ends_at)
      end
    end

    assignments_for_ledger =
      forecast_person.forecast_assignments
        .includes(:forecast_project)
        .where(
          "end_date >= ? AND start_date <= ?",
          ledger_starts_at,
          ledger_ends_at,
        )
        .to_a

    periods = Stacks::Period.for_gradation(:month, ledger_starts_at, ledger_ends_at).reverse
    periods.reduce({ all: [], by_month: {} }) do |acc, period|
      contributor_payouts_in_period = preloaded_contributor_payouts.select do |cp|
        cp.invoice_tracker.invoice_pass.start_of_month >= period.starts_at &&
        cp.invoice_tracker.invoice_pass.start_of_month <= period.ends_at
      end

      reimbursements_in_period = preloaded_reimbursements.select do |cp|
        cp.created_at >= period.starts_at &&
        cp.created_at <= period.ends_at
      end

      trueups_in_period = preloaded_trueups.select do |tu|
        tu.payment_date >= period.starts_at &&
        tu.payment_date <= period.ends_at
      end

      profit_shares_in_period = preloaded_profit_shares.select do |ps|
        ps.applied_at >= period.starts_at &&
        ps.applied_at <= period.ends_at
      end

      adjustments_in_period = preloaded_adjustments.select do |adj|
        adj.effective_on >= period.starts_at &&
        adj.effective_on <= period.ends_at
      end

      deel_invoice_in_period = preloaded_deel_invoice_adjustments.select do |dia|
        dia.date_submitted >= period.starts_at &&
        dia.date_submitted <= period.ends_at
      end

      pay_stubs_in_period = preloaded_pay_stubs.select do |ps|
        ps.effective_on_for_display >= period.starts_at &&
        ps.effective_on_for_display <= period.ends_at
      end

      withdrawal_requests_in_period = preloaded_withdrawal_requests.select do |wr|
        d = wr.effective_on_for_display
        d.present? && d >= period.starts_at && d <= period.ends_at
      end

      sorted =
        [
          *contributor_payouts_in_period,
          *trueups_in_period,
          *reimbursements_in_period,
          *profit_shares_in_period,
          *adjustments_in_period,
          *deel_invoice_in_period,
          *pay_stubs_in_period,
          *withdrawal_requests_in_period,
        ].sort do |a, b|
        date_a = nil
        if a.is_a?(Trueup)
          date_a = a.payment_date
        elsif a.is_a?(Reimbursement)
          date_a = a.created_at
        elsif a.is_a?(ContributorPayout)
          date_a = a.invoice_tracker.invoice_pass.start_of_month
        elsif a.is_a?(ProfitShare)
          date_a = a.applied_at
        elsif a.is_a?(ContributorAdjustment)
          date_a = a.effective_on
        elsif a.is_a?(DeelInvoiceAdjustment)
          date_a = a.date_submitted
        elsif a.is_a?(PayStub)
          date_a = a.effective_on_for_display
        elsif a.is_a?(LedgerWithdrawalRequest)
          date_a = a.effective_on_for_display
        end

        date_b = nil
        if b.is_a?(Trueup)
          date_b = b.payment_date
        elsif b.is_a?(Reimbursement)
          date_b = b.created_at
        elsif b.is_a?(ContributorPayout)
          date_b = b.invoice_tracker.invoice_pass.start_of_month
        elsif b.is_a?(ProfitShare)
          date_b = b.applied_at
        elsif b.is_a?(ContributorAdjustment)
          date_b = b.effective_on
        elsif b.is_a?(DeelInvoiceAdjustment)
          date_b = b.date_submitted
        elsif b.is_a?(PayStub)
          date_b = b.effective_on_for_display
        elsif b.is_a?(LedgerWithdrawalRequest)
          date_b = b.effective_on_for_display
        end

        date_b <=> date_a
      end

      acc[:all] = [*acc[:all], *sorted]

      total_hours =
        forecast_person.recorded_allocation_during_range_in_hours_from_assignments(
          assignments_for_ledger,
          period.starts_at,
          period.ends_at,
        )
      total_income = (sorted.reduce(0) do |acc, item|
        if item.is_a?(Trueup)
          next acc += item.amount
        elsif item.is_a?(ContributorPayout)
          next acc += item.amount
        end
        acc
      end)

      ftp = nil
      partial_salary = 0
      if include_salary && admin_user.present?
        ftp = contiguous_ftps.find do |ftp|
          ftp[:started_at] <= period.starts_at && ftp[:ended_at] >= period.ends_at
        end

        broken_ftp = contiguous_ftps.find do |ftp|
          ftp[:started_at] <= period.starts_at && ftp[:ended_at] < period.ends_at && ftp[:ended_at].month == period.ends_at.month && ftp[:ended_at].year == period.ends_at.year
        end

        if ftp.nil? && broken_ftp.present?
          partial_salary = (period.starts_at..period.ends_at).reduce(0) do |acc, date|
            acc += admin_user.cost_of_employment_on_date(date, 1)
            acc
          end
        end
      end

      acc[:by_month][period] = {
        items: sorted,
        total_hours: total_hours,
        total_income: total_income,
        partial_salary: partial_salary,
        fulltime: ftp.present?,
        elevated_service: ftp.present? || (total_hours >= 120 || (partial_salary + total_income) >= 9000)
      }
      acc
    end
  end

  # Convenience predicate: was this contributor in "elevated service" for `period`,
  # computed across all enterprises. Defaults to a single-month window scoped query
  # so callers don't pay the full-history cost when checking one month.
  def elevated_service_for_month(period, items_result = all_items_grouped_by_month(false, period.starts_at, period.ends_at + 1.day))
    data = items_result[:by_month][period]
    !!(data && data[:elevated_service])
  end

end
