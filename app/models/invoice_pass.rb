class InvoicePass < ApplicationRecord
  def complete?
    completed_at.present?
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
