class ForecastClient < ApplicationRecord
  self.primary_key = "forecast_id"
  has_many :forecast_projects, class_name: "ForecastProject", foreign_key: "client_id"

  attr_accessor :_qbo_customer
  attr_accessor :_qbo_term

  def edit_link
    "https://forecastapp.com/864444/clients/#{forecast_id}/edit"
  end

  def is_internal?
    [*Studio.all.map(&:name), 'garden3d'].include?(name)
  end

  def qbo_term
    @_qbo_term ||= (
      bearer =
        Stacks::System.singleton_class::QBO_NOTES_PAYMENT_TERM_BEARER
      default =
        Stacks::System.singleton_class::DEFAULT_PAYMENT_TERM
      qbo_terms =
        Stacks::Quickbooks.fetch_all_terms

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
      qbo_customers = qbo_customers || Stacks::Quickbooks.fetch_all_customers
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
