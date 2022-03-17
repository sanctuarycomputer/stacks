class Stacks::Quickbooks
  class << self
    def sync_all!
      sync_monthly_profit_and_loss_reports!
      sync_quarterly_profit_and_loss_reports!
      sync_yearly_profit_and_loss_reports!
    end

    def sync_monthly_profit_and_loss_reports!
      time = Date.new(2020, 1, 1)
      while time < Date.today
        QboProfitAndLossReport.find_or_fetch_for_range(
          time.beginning_of_month,
          time.end_of_month,
          true
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
          true
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
          true
        )
        time = time.advance(years: 1)
      end
    end

    def make_and_refresh_qbo_access_token
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

      # Refresh the token if it's been longer than 45 minutes
      if ((DateTime.now.to_i - qbo_token.created_at.to_i) / 60) > 45
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

    def fetch_invoice_by_id(id)
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      invoice_service = Quickbooks::Service::Invoice.new
      invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      invoice_service.access_token = access_token
      invoice_service.fetch_by_id(id)
    end

    def fetch_invoices_by_memo(memo)
      access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token

      invoice_service = Quickbooks::Service::Invoice.new
      invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      invoice_service.access_token = access_token

      qbo_invoices = invoice_service.all
      qbo_invoices.select{|i| i.private_note == memo}
    end

    def fetch_profit_and_loss_report_for_range(start_of_range, end_of_range)
      qbo_access_token = Stacks::Quickbooks.make_and_refresh_qbo_access_token
      report_service = Quickbooks::Service::Reports.new
      report_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      report_service.access_token = qbo_access_token

      report_service.query("ProfitAndLoss", nil, {
        start_date: start_of_range.strftime("%Y-%m-%d"),
        end_date: end_of_range.strftime("%Y-%m-%d"),
      })
    end
  end
end
