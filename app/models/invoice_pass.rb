class InvoicePass < ApplicationRecord
  has_many :invoice_trackers

  def complete?
    completed_at.present?
  end

  def make_trackers!
    clients_served.each do |c|
      InvoiceTracker.find_or_create_by!(
        forecast_client_id: c.forecast_id,
        invoice_pass: self
      )
    end
  end

  def recover_all_trackers!
    qbo_invoice_candidates =
      Stacks::Quickbooks.fetch_invoices_by_memo(invoice_month)
    invoice_trackers.each do |it|
      it.recover!(qbo_invoice_candidates)
    end
  end

  def clients_served
    assignments =
      ForecastAssignment
        .includes(forecast_project: :forecast_client)
      .where('end_date >= ? AND start_date <= ?', start_of_month, start_of_month.end_of_month)

    internal_client_names =
      [*Studio.all.map(&:name), 'garden3d']

    clients =
      assignments
        .map{|a| a.forecast_project.forecast_client}.compact.uniq
        .reject{|c| internal_client_names.include?(c.name)}
  end

  def invoice_month
    start_of_month.strftime("%B %Y")
  end

  def latest_generator_pass_date
    (data || {})["generator_passes"].keys.map{|ds| DateTime.parse(ds)}.max
  end

  def latest_generator_pass
    return nil if latest_generator_pass_date.nil?
    (data || {})["generator_passes"][latest_generator_pass_date.iso8601]
  end

  def latest_invoice_ids
    (
      latest_generator_pass["existing"] +
      latest_generator_pass["generated"]
    ).map{|i| i.dig("qbo_invoice", "id")}
  end

  def latest_reminder_pass_date
    (data || {})["reminder_passes"].keys.map{|ds| DateTime.parse(ds)}.max
  end

  def latest_reminder_pass
    return nil if latest_reminder_pass_date.nil?
    (data || {})["reminder_passes"][latest_reminder_pass_date.iso8601]
  end
end
