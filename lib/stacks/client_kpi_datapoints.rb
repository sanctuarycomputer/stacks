# Builds the four client & pipeline OKR datapoint entries that
# Studio#key_datapoints_for_period merges into its result. Each entry is
# shaped like the existing datapoints: { value:, unit:, extras: }.
class Stacks::ClientKpiDatapoints
  def self.call(period:, leads:, client_revenue:)
    new(period: period, leads: leads, client_revenue: client_revenue).call
  end

  def initialize(period:, leads:, client_revenue:)
    @period = period
    @leads = leads
    @client_revenue = client_revenue
  end

  def call
    {
      average_client_lifetime_value: {
        value: @client_revenue.average_lifetime_value_asof(@period.ends_at),
        unit: :usd,
        extras: { client_count: client_count, skipped_tracker_count: @client_revenue.skipped_tracker_count }
      },
      average_client_tenure: {
        value: @client_revenue.average_tenure_months_asof(@period.ends_at),
        unit: :months,
        extras: { client_count: client_count, skipped_tracker_count: @client_revenue.skipped_tracker_count }
      },
      client_revenue_concentration: {
        value: concentration[:value],
        unit: :percentage,
        extras: {
          top_client_name: concentration[:top_client_name],
          top_client_amount: concentration[:top_client_amount],
          total_revenue: concentration[:total_revenue],
          skipped_tracker_count: @client_revenue.skipped_tracker_count
        }
      },
      forecasted_sales_revenue: {
        value: budgets.sum,
        unit: :usd,
        extras: {
          open_lead_count: open_leads.count,
          budgeted_lead_count: budgets.count
        }
      }
    }
  end

  private

  def open_leads
    @_open_leads ||= @leads.select(&:open?)
  end

  def budgets
    @_budgets ||= open_leads.filter_map(&:estimated_budget)
  end

  def concentration
    @_concentration ||= @client_revenue.concentration_for_range(@period.starts_at, @period.ends_at)
  end

  def client_count
    @_client_count ||= @client_revenue.client_count_asof(@period.ends_at)
  end
end
