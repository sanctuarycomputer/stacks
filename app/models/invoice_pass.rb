class InvoicePass < ApplicationRecord
  has_many :invoice_trackers

  def complete?
    completed_at.present?
  end

  def allows_payment_splits?
    start_of_month >= Stacks::System.singleton_class::NEW_DEAL_START_AT
  end

  def statuses
    if (data || {})["reminder_passes"].present? && latest_reminder_pass.any?
      :missing_hours
    else
      status = invoice_trackers.map(&:status)
      status.inject(Hash.new(0)) { |h, e| h[e] += 1 ; h }
    end
  end

  def payout_statuses
    return [] unless allows_payment_splits?
    status = invoice_trackers.map(&:contributor_payouts_status)
    status.inject(Hash.new(0)) { |h, e| h[e] += 1 ; h }
  end

  def value
    invoice_trackers.map(&:value).compact.reduce(&:+)
  end

  def balance
    invoice_trackers.map(&:balance).compact.reduce(&:+)
  end

  def make_trackers!
    return if statuses == :missing_hours
    clients_served.each do |c|
      InvoiceTracker.find_or_create_by!(
        forecast_client_id: c.forecast_id,
        invoice_pass: self
      )
    end
  end

  def clients_served
    Stacks::System.clients_served_since(start_of_month, start_of_month.end_of_month)
  end

  def period
    Stacks::Period.new(invoice_month, start_of_month, start_of_month.end_of_month)
  end

  def invoice_month
    start_of_month.strftime("%B %Y")
  end

  def latest_reminder_pass_date
    (data || {})["reminder_passes"].keys.map{|ds| DateTime.parse(ds)}.max
  end

  def latest_reminder_pass
    return nil if latest_reminder_pass_date.nil?
    (data || {})["reminder_passes"][latest_reminder_pass_date.iso8601]
  end

  ## TODO: Remove the below when we move away from automator
  def latest_generator_pass_date
    (data || {})["generator_passes"].keys.map{|ds| DateTime.parse(ds)}.max
  end

  def latest_generator_pass
    return nil if latest_generator_pass_date.nil?
    (data || {})["generator_passes"][latest_generator_pass_date.iso8601]
  end
end
