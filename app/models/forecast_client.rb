class ForecastClient < ApplicationRecord
  self.primary_key = "forecast_id"
  has_many :forecast_projects, class_name: "ForecastProject", foreign_key: "client_id"

  has_one :enterprise_forecast_client, dependent: :destroy
  has_one :enterprise, through: :enterprise_forecast_client

  def billing_enterprise
    enterprise || Enterprise.sanctuary
  end

  attr_accessor :_qbo_customer
  attr_accessor :_qbo_term

  def edit_link
    "https://forecastapp.com/864444/clients/#{forecast_id}/edit"
  end

  # A forecast client is "internal" if and only if it's mapped to an
  # enterprise via the enterprise_forecast_clients join. Internal clients
  # generate pay stubs against that enterprise's ledger; external clients
  # (unmapped) flow through the InvoiceTracker pipeline and are billed by
  # Sanctuary by default.
  #
  # Until 2026-05-13 this used a hardcoded `INTERNAL_CLIENTS` constant —
  # the migration MigrateInternalClientsToEnterpriseForecastClients seeded
  # the join from those names so this refactor doesn't regress behavior.
  def is_internal?
    enterprise_forecast_client.present?
  end

  def qbo_term
    @_qbo_term ||= (
      bearer =
        Stacks::System.singleton_class::QBO_NOTES_PAYMENT_TERM_BEARER
      default =
        Stacks::System.singleton_class::DEFAULT_PAYMENT_TERM
      # Route through billing_enterprise.qbo_account so internal clients
      # mapped to another enterprise look up terms in THEIR QBO. External
      # (unmapped) clients fall through to Sanctuary via the billing_enterprise
      # default — same behavior as before.
      qa = billing_enterprise&.qbo_account
      return nil if qa.nil?
      qbo_terms = qa.fetch_all_terms

      term_mapping = (qbo_customer.try(:notes) || "").split(" ").find do |word|
        word.starts_with?(bearer)
      end

      if term_mapping.present?
        term_days = term_mapping.split(bearer)[1].to_i
        qbo_terms.find { |t| t.due_days == term_days }
      else
        qbo_terms.find { |t| t.due_days == default }
      end
    )
  end

  # TODO: Sync qbo_customer and join?
  def qbo_customer(qbo_customers = nil)
    @_qbo_customer ||= (
      # Same routing as qbo_term: derive the QBO account from this client's
      # billing_enterprise (external clients default to Sanctuary).
      qa = billing_enterprise&.qbo_account
      return nil if qbo_customers.nil? && qa.nil?
      qbo_customers = qbo_customers || qa.fetch_all_customers
      bearer =
        Stacks::System.singleton_class::QBO_NOTES_FORECAST_MAPPING_BEARER
      qbo_customers.find do |c|
        mapping = (c.notes || "").split(" ").find do |word|
          word.starts_with?(bearer)
        end
        if mapping.present?
          splat = mapping.split(bearer)[1]
          splat = splat.gsub!(/_/, " ") if splat.include?("_")
          splat == name
        else
          c.company_name == name
        end
      end
    )
  end
end
