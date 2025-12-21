# TODO: Slowly deprecate this for qbo_account.rb now that we have
# enterprises with different QBO credentials.

class Stacks::Quickbooks
  class << self
    def sync_all!
      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_monthly_profit_and_loss_reports!
      end

      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_quarterly_profit_and_loss_reports!
      end

      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_yearly_profit_and_loss_reports!
      end

      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_all_invoices!
      end

      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_all_vendors!
      end

      Retriable.retriable(tries: 5, base_interval: 1, multiplier: 2, max_interval: 10) do
        sync_all_bills!
      end
    end

    def sync_all_invoices!
      data = fetch_all_invoices.map do |i|
        {
          qbo_id: i["id"],
          data: i.as_json,
        }
      end
      QboInvoice.upsert_all(data, unique_by: :qbo_id)
    end

    def sync_monthly_profit_and_loss_reports!
      time = Date.new(2020, 1, 1)
      while time < Date.today
        QboProfitAndLossReport.find_or_fetch_for_range(
          time.beginning_of_month,
          time.end_of_month,
          true,
          nil
        )
        time = time.advance(months: 1)
      end
    end

    def sync_quarterly_profit_and_loss_reports!
      time = Date.new(2020, 1, 1)
      while time < Date.today
        QboProfitAndLossReport.find_or_fetch_for_range(
          time.beginning_of_quarter,
          time.end_of_quarter,
          true,
          nil
        )
        time = time.advance(months: 3)
      end
    end

    def sync_yearly_profit_and_loss_reports!
      time = Date.new(2020, 1, 1)
      while time < Date.today
        QboProfitAndLossReport.find_or_fetch_for_range(
          time.beginning_of_year,
          time.end_of_year,
          true,
          nil
        )
        time = time.advance(years: 1)
      end
    end

    def sync_all_vendors!
      data = fetch_all_vendors.map do |v|
        {
          qbo_id: v["id"],
          data: v.as_json,
        }
      end
      QboVendor.upsert_all(data, unique_by: :qbo_id)
      QboVendor.where.not(qbo_id: data.map{|t| t[:qbo_id]}).delete_all
    end

    def sync_all_bills!
      data = fetch_all_bills.map do |b|
        {
          qbo_id: b["id"],
          data: b.as_json,
          qbo_vendor_id: b.vendor_ref.value
        }
      end
      QboBill.upsert_all(data, unique_by: :qbo_id)
      QboBill.where.not(qbo_id: data.map{|t| t[:qbo_id]}).delete_all
    end

    def make_and_refresh_qbo_access_token(force_refresh = false)
      oauth2_client = OAuth2::Client.new(Stacks::Utils.config[:quickbooks][:client_id], Stacks::Utils.config[:quickbooks][:client_secret], {
        site: "https://appcenter.intuit.com/connect/oauth2",
        authorize_url: "https://appcenter.intuit.com/connect/oauth2",
        token_url: "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer",
      })
      qbo_token = QuickbooksToken.order("created_at").last
      access_token = OAuth2::AccessToken.new(
        oauth2_client,
        qbo_token.token,
        refresh_token: qbo_token.refresh_token
      )

      # Refresh the token if it's been longer than 10 minutes
      if force_refresh || (((DateTime.now.to_i - qbo_token.created_at.to_i) / 60) > 10)
        access_token = access_token.refresh!
        new_qbo_token =
          QuickbooksToken.create!(
            token: access_token.token,
            refresh_token: access_token.refresh_token
          )
        QuickbooksToken.where.not(id: new_qbo_token.id).delete_all
      end

      access_token
    end

    def fetch_all_vendors
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      service = Quickbooks::Service::Vendor.new
      service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      service.access_token = access_token
      service.all
    end

    def fetch_all_invoices
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      service = Quickbooks::Service::Invoice.new
      service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      service.access_token = access_token
      service.all
    end

    def fetch_all_accounts
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      # Get all accounts (ie, "[SC] Payroll")
      service = Quickbooks::Service::Account.new
      service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      service.access_token = access_token
      service.all
    end

    def fetch_all_terms
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      # Get all terms (ie, "Net 15")
      terms_service = Quickbooks::Service::Term.new
      terms_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      terms_service.access_token = access_token
      qbo_terms = terms_service.all
    end

    def fetch_all_items
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      items_service = Quickbooks::Service::Item.new
      items_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      items_service.access_token = access_token
      qbo_items = items_service.all
      default_service_item = qbo_items.find { |s| s.fully_qualified_name == "Services" }

      [qbo_items, default_service_item]
    end

    def fetch_all_customers
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      # Get all Customers
      service = Quickbooks::Service::Customer.new
      service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      service.access_token = access_token
      qbo_customers = service.all
    end

    def fetch_all_bills
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      # Get all Bills
      service = Quickbooks::Service::Bill.new
      service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      service.access_token = access_token
      qbo_bills = service.all
    end

    def fetch_bill_by_id(id)
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      bill_service = Quickbooks::Service::Bill.new
      bill_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      bill_service.access_token = access_token
      bill_service.fetch_by_id(id)
    end

    def fetch_invoice_by_id(id)
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      invoice_service = Quickbooks::Service::Invoice.new
      invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      invoice_service.access_token = access_token
      invoice_service.fetch_by_id(id)
    end

    def fetch_profit_and_loss_report_for_range(start_of_range, end_of_range, accounting_method = "Cash")
      qbo_access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token
      report_service = Quickbooks::Service::ReportsJSON.new
      report_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      report_service.access_token = qbo_access_token

      report_service.query("ProfitAndLoss", nil, {
        start_date: start_of_range.strftime("%Y-%m-%d"),
        end_date: end_of_range.strftime("%Y-%m-%d"),
        accounting_method: accounting_method,
      })
    end
  end
end
