class Stacks::Quickbooks
  class << self
    def fetch_all_customers
      access_token = Stacks::Automator.make_and_refresh_qbo_access_token

      # Get all Customers
      service = Quickbooks::Service::Customer.new
      service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      service.access_token = access_token
      qbo_customers = service.all
    end

    def fetch_invoice_by_id(id)
      access_token = Stacks::Automator.make_and_refresh_qbo_access_token

      invoice_service = Quickbooks::Service::Invoice.new
      invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      invoice_service.access_token = access_token
      invoice_service.fetch_by_id(id)
    end

    def fetch_invoices_by_memo(memo)
      access_token = Stacks::Automator.make_and_refresh_qbo_access_token

      invoice_service = Quickbooks::Service::Invoice.new
      invoice_service.company_id = Stacks::Utils.config[:quickbooks][:realm_id]
      invoice_service.access_token = access_token

      qbo_invoices = invoice_service.all
      qbo_invoices.select{|i| i.private_note == memo}
    end
  end
end
