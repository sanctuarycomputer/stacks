class ForecastClient < ApplicationRecord
  self.primary_key = "forecast_id"
  has_many :forecast_projects, class_name: "ForecastProject", foreign_key: "client_id"

  # TODO: Sync qbo_customer and join?
  def qbo_customer
    qbo_customers =
      Stacks::Quickbooks.fetch_all_customers
    bearer =
      Stacks::System.singleton_class::QBO_NOTES_FORECAST_MAPPING_BEARER
    qbo_customers.find do |c|
      mapping = (c.notes || "").split(" ").find do |word|
        word.starts_with?(bearer)
      end
      if mapping
        splat = mapping.split(bearer)[1]
        splat = splat.gsub!(/_/, " ") if splat.include?("_")
        splat == name
      else
        c.company_name == name
      end
    end
  end
end
