class QboAccount < ApplicationRecord
  belongs_to :enterprise
  has_one :qbo_token
  has_many :qbo_profit_and_loss_reports
  accepts_nested_attributes_for :qbo_token, allow_destroy: true

  # TODO as more enterprises come online, make this a column
  def started_at
     Date.new(2023, 1, 1)
  end

  def sync_all!
    sync_monthly_profit_and_loss_reports!
    sync_quarterly_profit_and_loss_reports!
    sync_yearly_profit_and_loss_reports!
  end

  def sync_monthly_profit_and_loss_reports!
    time = started_at
    while time < Date.today
      QboProfitAndLossReport.find_or_fetch_for_range(
        time.beginning_of_month,
        time.end_of_month,
        true,
        self
      )
      time = time.advance(months: 1)
    end
  end

  def sync_quarterly_profit_and_loss_reports!
    time = started_at
    while time < Date.today
      QboProfitAndLossReport.find_or_fetch_for_range(
        time.beginning_of_quarter,
        time.end_of_quarter,
        true,
        self
      )
      time = time.advance(months: 3)
    end
  end

  def sync_yearly_profit_and_loss_reports!
    time = started_at
    while time < Date.today
      QboProfitAndLossReport.find_or_fetch_for_range(
        time.beginning_of_year,
        time.end_of_year,
        true,
        self
      )
      time = time.advance(years: 1)
    end
  end

  # Lightweight liveness check. Hits QBO's /companyinfo/{realmId} endpoint,
  # which is the cheapest authenticated call the API offers, and returns the
  # CompanyInfo object on success so callers can `pp` company name / country /
  # fiscal year start as a richer "yes it works" signal than a bare boolean.
  # Returns nil when no qbo_token has been authorized yet (same convention as
  # make_and_refresh_qbo_access_token). Re-raises auth / network errors so the
  # real cause is visible in `rails c`.
  def ping
    qbo_access_token = make_and_refresh_qbo_access_token
    return nil if qbo_access_token.nil?
    service = Quickbooks::Service::CompanyInfo.new
    service.company_id = realm_id
    service.access_token = qbo_access_token
    service.fetch_by_id(realm_id)
  end

  def fetch_all_accounts
    qbo_access_token = make_and_refresh_qbo_access_token
    service = Quickbooks::Service::Account.new
    service.company_id = realm_id
    service.access_token = qbo_access_token
    service.all
  end

  def fetch_profit_and_loss_report_for_range(start_of_range, end_of_range, accounting_method = "Cash")
    qbo_access_token = make_and_refresh_qbo_access_token
    report_service = Quickbooks::Service::ReportsJSON.new
    report_service.company_id = realm_id
    report_service.access_token = qbo_access_token

    report_service.query("ProfitAndLoss", nil, {
      start_date: start_of_range.strftime("%Y-%m-%d"),
      end_date: end_of_range.strftime("%Y-%m-%d"),
      accounting_method: accounting_method
    })
  end

  # `force: true` always refreshes regardless of the 10-minute staleness gate
  # — used by QboTokens::RefreshAll at the start of daily tasks so downstream
  # work can rely on a guaranteed-fresh token rather than racing the gate.
  def make_and_refresh_qbo_access_token(force: false)
    oauth2_client = OAuth2::Client.new(client_id, client_secret, {
      site: "https://appcenter.intuit.com/connect/oauth2",
      authorize_url: "https://appcenter.intuit.com/connect/oauth2",
      token_url: "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer",
    })

    return nil if qbo_token.nil?

    access_token = OAuth2::AccessToken.new(
      oauth2_client,
      qbo_token.token,
      refresh_token: qbo_token.refresh_token
    )

    stale = ((DateTime.now.to_i - qbo_token.updated_at.to_i) / 60) >= 10
    if force || stale
      access_token = access_token.refresh!
      qbo_token.update!(
        token: access_token.token,
        refresh_token: access_token.refresh_token
      )
    end

    access_token
  end

  def fetch_all_vendors
    qbo_access_token = make_and_refresh_qbo_access_token
    service = Quickbooks::Service::Vendor.new
    service.company_id = realm_id
    service.access_token = qbo_access_token
    service.all
  end

  def fetch_all_invoices
    qbo_access_token = make_and_refresh_qbo_access_token
    service = Quickbooks::Service::Invoice.new
    service.company_id = realm_id
    service.access_token = qbo_access_token
    service.all
  end

  # Per-request memoized only — the quickbooks-ruby gem's Customer/Term
  # objects carry Procs that don't marshal, so Rails.cache (file/memcache
  # in prod) raises "no _dump_data is defined for class Proc". Each request
  # still pays the first fetch, but repeats inside the same render
  # short-circuit to the @-var.
  def fetch_all_terms
    @_fetch_all_terms ||= begin
      qbo_access_token = make_and_refresh_qbo_access_token
      terms_service = Quickbooks::Service::Term.new
      terms_service.company_id = realm_id
      terms_service.access_token = qbo_access_token
      terms_service.all
    end
  end

  def fetch_all_items
    qbo_access_token = make_and_refresh_qbo_access_token
    items_service = Quickbooks::Service::Item.new
    items_service.company_id = realm_id
    items_service.access_token = qbo_access_token
    qbo_items = items_service.all
    default_service_item = qbo_items.find { |s| s.fully_qualified_name == "Services" }
    [qbo_items, default_service_item]
  end

  def fetch_all_customers
    @_fetch_all_customers ||= begin
      qbo_access_token = make_and_refresh_qbo_access_token
      service = Quickbooks::Service::Customer.new
      service.company_id = realm_id
      service.access_token = qbo_access_token
      service.all
    end
  end

  def fetch_all_bills
    qbo_access_token = make_and_refresh_qbo_access_token
    service = Quickbooks::Service::Bill.new
    service.company_id = realm_id
    service.access_token = qbo_access_token
    service.all
  end

  def delete_bill(bill)
    qbo_access_token = make_and_refresh_qbo_access_token
    service = Quickbooks::Service::Bill.new
    service.company_id = realm_id
    service.access_token = qbo_access_token
    service.delete(bill)
  end

  def fetch_bill_by_id(id)
    qbo_access_token = make_and_refresh_qbo_access_token
    bill_service = Quickbooks::Service::Bill.new
    bill_service.company_id = realm_id
    bill_service.access_token = qbo_access_token
    bill_service.fetch_by_id(id)
  end

  def fetch_invoice_by_id(id)
    qbo_access_token = make_and_refresh_qbo_access_token
    invoice_service = Quickbooks::Service::Invoice.new
    invoice_service.company_id = realm_id
    invoice_service.access_token = qbo_access_token
    invoice_service.fetch_by_id(id)
  end

  def sync_all_invoices!
    data = fetch_all_invoices.map do |i|
      { qbo_id: i["id"], qbo_account_id: id, data: i.as_json }
    end
    QboInvoice.upsert_all(data, unique_by: :index_qbo_invoices_on_qbo_account_and_qbo_id) if data.any?
  end

  def sync_all_vendors!
    data = fetch_all_vendors.map do |v|
      { qbo_id: v.id, qbo_account_id: id, data: v.as_json }
    end
    QboVendor.upsert_all(data, unique_by: :index_qbo_vendors_on_qbo_account_and_qbo_id) if data.any?
  end

  def sync_all_bills!
    data = fetch_all_bills.map do |b|
      { qbo_id: b["id"], qbo_account_id: id, data: b.as_json, qbo_vendor_id: b.vendor_ref.value }
    end
    QboBill.upsert_all(data, unique_by: :index_qbo_bills_on_qbo_account_and_qbo_id) if data.any?

    # Any local QboBill rows whose qbo_id no longer exists in QBO need to be
    # cleaned up. There's no `qbo_bill` AR association on host rows anymore
    # (it was replaced by a composite-scoped method in SyncsAsQboBill); detach
    # by qbo_bill_id strings, which is what host rows actually store.
    deleted_bills = QboBill.where(qbo_account_id: id).where.not(qbo_id: data.map { |t| t[:qbo_id] })
    deleted_qbo_ids = deleted_bills.pluck(:qbo_id)
    if deleted_qbo_ids.any?
      # Every SyncsAsQboBill host has to be detached when its remote bill
      # vanishes — otherwise the host still points at a dead qbo_id, gets
      # surfaced as "No QBO bill" on the Money page, and a "Sync to QBO" click
      # creates a duplicate bill in QBO vendor AP. Keep this list aligned with
      # Money::PayableQboBills::HOST_KLASSES.
      ContributorPayout.with_deleted.where(qbo_bill_id: deleted_qbo_ids).update_all(qbo_bill_id: nil)
      Trueup.with_deleted.where(qbo_bill_id: deleted_qbo_ids).update_all(qbo_bill_id: nil)
      ContributorAdjustment.with_deleted.where(qbo_bill_id: deleted_qbo_ids).update_all(qbo_bill_id: nil)
      ProfitShare.with_deleted.where(qbo_bill_id: deleted_qbo_ids).update_all(qbo_bill_id: nil)
      PayStub.with_deleted.where(qbo_bill_id: deleted_qbo_ids).update_all(qbo_bill_id: nil)
      Reimbursement.with_deleted.where(qbo_bill_id: deleted_qbo_ids).update_all(qbo_bill_id: nil)
    end
    deleted_bills.delete_all
  end

  def cleanup_orphaned_qbo_objects!
    fetch_all_bills.each do |b|
      splat = (b.doc_number || "").match(/^Stacks_(\d+)(?:_([A-Za-z][A-Za-z0-9_]*\.{3}?))?$/)
      next unless splat.present?

      case splat[2]
      when "CP"
        klass = ContributorPayout
      when "TU"
        klass = Trueup
      when "CA"
        klass = ContributorAdjustment
      when "PS"
        klass = ProfitShare
      when "SB"
        klass = PayStub
      when "RB"
        klass = Reimbursement
      when "ContributorPayout", /^Contri/
        klass = ContributorPayout
      when "Trueup"
        klass = Trueup
      when "ProfitShare", /^Profit/
        klass = ProfitShare
      else
        klass = nil
      end

      if klass.present?
        obj = klass.find_by(id: splat[1])
        next if obj.present?

        if deleted_obj = klass.with_deleted.find_by(id: splat[1])
          deleted_obj.update(qbo_bill_id: nil)
          deleted_obj.qbo_bill.destroy! if deleted_obj.qbo_bill.present?
          next
        end
      end

      # Last defense: even when this bill's doc_number suffix is unknown OR
      # the known-class lookups came up empty, refuse to destroy the bill if
      # ANY SyncsAsQboBill host still references its qbo_id. Otherwise we'd
      # nuke a healthy bill whose label is malformed/legacy/unknown.
      next if Money::PayableQboBills::HOST_KLASSES.any? { |k| k.with_deleted.where(qbo_bill_id: b.id).exists? }

      # Truly orphan now — clean up local mirror (which also tears down the
      # remote via QboBill#before_destroy) or delete the remote directly.
      if qbo_bill = QboBill.where(qbo_account_id: id).find_by(qbo_id: b.id)
        qbo_bill.destroy!
      else
        delete_bill(b)
      end
    end
  end
end
