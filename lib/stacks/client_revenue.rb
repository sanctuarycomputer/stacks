# Per-client invoiced revenue for a studio, derived from InvoiceTracker
# history (June 2021 onward). Countable revenue = trackers with a linked,
# non-voided QBO invoice on an external client. garden3d counts full invoice
# totals; sub-studios take a pro-rata share via blueprint person lines
# (person -> studio by Forecast roles), the same attribution the cost
# explorer uses. Feeds the average_client_lifetime_value,
# average_client_tenure, and client_revenue_concentration OKR datapoints.
class Stacks::ClientRevenue
  Row = Struct.new(:client, :month, :amount, keyword_init: true)

  attr_reader :skipped_tracker_count

  # The raw Row(client, month, amount) set, oldest data first by construction
  # order. Exposed for read-only consumers (e.g. the MCP client-revenue tool)
  # so they reuse this math instead of rebuilding it.
  attr_reader :rows

  def initialize(studio, preloaded_studios = Studio.all, trackers = nil)
    @studio = studio
    @preloaded_studios = preloaded_studios
    @trackers = trackers || self.class.all_trackers
    @skipped_tracker_count = 0
    @rows = build_rows
  end

  def self.all_trackers
    InvoiceTracker
      .includes(:invoice_pass, :qbo_invoice, forecast_client: :enterprise_forecast_client)
      .to_a
  end

  def average_lifetime_value_asof(date)
    totals = totals_by_client_asof(date)
    return 0 if totals.empty?
    totals.values.sum / totals.length
  end

  def average_tenure_months_asof(date)
    rows = @rows.select { |r| r.month <= date }
    return 0 if rows.empty?
    tenures = rows.group_by(&:client).values.map do |client_rows|
      first, last = client_rows.map(&:month).minmax
      (last.year * 12 + last.month) - (first.year * 12 + first.month)
    end
    tenures.sum.to_f / tenures.length
  end

  def client_count_asof(date)
    totals_by_client_asof(date).length
  end

  def concentration_for_range(starts_at, ends_at)
    in_range = @rows.select { |r| r.month >= starts_at.beginning_of_month && r.month <= ends_at }
    total = in_range.sum(&:amount)
    return { value: 0, top_client_name: nil, top_client_amount: 0, total_revenue: 0 } if total.zero?

    top_client, top_amount = in_range
      .group_by(&:client)
      .transform_values { |rs| rs.sum(&:amount) }
      .max_by { |_, amount| amount }

    {
      value: (top_amount / total) * 100,
      top_client_name: top_client.name,
      top_client_amount: top_amount,
      total_revenue: total
    }
  end

  private

  def totals_by_client_asof(date)
    @rows
      .select { |r| r.month <= date }
      .group_by(&:client)
      .transform_values { |rs| rs.sum(&:amount) }
  end

  def build_rows
    @trackers.filter_map do |tracker|
      begin
        invoice = tracker.qbo_invoice
        client = tracker.forecast_client

        # Guard: skip invoices with no stored data to prevent the lazy live-QBO
        # sync in QboInvoice#data from firing inside the nightly snapshot hot
        # path. Use read_attribute to bypass the lazy-sync override in #data.
        # These are data-quality drops, so they count toward skipped_tracker_count.
        if invoice && invoice.read_attribute(:data).blank?
          @skipped_tracker_count += 1
          next
        end

        next if invoice.nil? || invoice.status == :voided
        next if client.nil? || client.is_internal?

        amount = @studio.is_garden3d? ? invoice.total : studio_share(tracker, invoice.total)
        next if amount.nil? || amount.zero?

        Row.new(client: client, month: tracker.invoice_pass.start_of_month, amount: amount)
      rescue => e
        Rails.logger.warn("[ClientRevenue] invoice_tracker=#{tracker.id} skipped: #{e.class}: #{e.message}")
        @skipped_tracker_count += 1
        nil
      end
    end
  end

  # Pro-rata share of the invoice total from blueprint lines whose person
  # belongs to this studio. Legacy lines without a forecast_person key fall
  # back to the [FP-<id>] description tag. Malformed lines are skipped and
  # logged; a tracker with no usable lines is omitted from sub-studio numbers
  # (it still counts for garden3d).
  def studio_share(tracker, invoice_total)
    lines = (tracker.blueprint || {})["lines"] || {}
    studio_sum = 0.0
    all_sum = 0.0

    lines.each do |description, line|
      unless line.is_a?(Hash) && line["quantity"].is_a?(Numeric) && line["unit_price"].is_a?(Numeric)
        Rails.logger.warn("[ClientRevenue] invoice_tracker=#{tracker.id} skipping malformed blueprint line #{description.inspect}")
        next
      end
      line_value = line["quantity"] * line["unit_price"]
      all_sum += line_value

      person_id = line["forecast_person"] || InvoiceTracker.forecast_person_id_from_description(description)
      next if person_id.nil?
      person = forecast_people_by_id[person_id]
      studio_sum += line_value if person&.studio(@preloaded_studios) == @studio
    end

    return nil if all_sum.zero?
    (studio_sum / all_sum) * invoice_total
  end

  def forecast_people_by_id
    @_forecast_people_by_id ||= ForecastPerson.all.index_by(&:forecast_id)
  end
end
