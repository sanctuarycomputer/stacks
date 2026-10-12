module Mso
  # garden3d's management fee invoices: one InvoiceTracker per paying company
  # on garden3d's invoice pass, and one $0.00 draft invoice per tracker in
  # garden3d's QuickBooks. Finance sets the amount in QuickBooks and sends the
  # invoice; Stacks never writes an amount and never sends one.
  #
  # NOTHING HERE WRITES TO QUICKBOOKS UNATTENDED. ensure_trackers! and
  # ensure_previous_month! touch the database only. push_invoice! and
  # create_drafts! write to QuickBooks and are reached only from an admin's
  # click (app/admin/invoice_passes.rb, app/admin/invoice_trackers.rb). Do not
  # call either from a rake task, a job or Stacks::Automator.
  class ManagementFeeInvoices
    class Error < StandardError; end
    class WrongPass < Error; end
    class Misconfigured < Error; end
    class PushFailed < Error; end

    LINE_DESCRIPTION = "Management fee"
    # Resolved by name in garden3d's QuickBooks. The QBO default item
    # "Services" posts to the same income account, so falling back to it would
    # work and be wrong; a missing item raises instead.
    ITEM_NAME = "Managerial Services"
    ZERO = BigDecimal("0")

    class << self
      # One tracker per management-fee payer on garden3d's pass. Idempotent.
      # Database only: no QuickBooks call of any kind.
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
            existing = InvoiceTracker
              .where(invoice_pass_id: invoice_pass.id, forecast_client_id: client_ids)
              .order(:id).first
            existing || InvoiceTracker.create!(
              invoice_pass: invoice_pass,
              forecast_client_id: client_ids.first,
              qbo_account: qbo_account,
            )
          end
        end
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
      def internal_client_ids!(payer)
        ids = EnterpriseForecastClient
          .where(enterprise_id: payer.id)
          .order(:forecast_client_id)
          .pluck(:forecast_client_id)
        if ids.empty?
          raise Misconfigured, "#{payer.name} is a management fee payer but has no internal Forecast client " \
                               "to hang its invoice tracker on"
        end
        ids
      end
    end
  end
end
