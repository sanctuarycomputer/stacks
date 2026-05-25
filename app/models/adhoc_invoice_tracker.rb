class AdhocInvoiceTracker < ApplicationRecord
  belongs_to :project_tracker
  belongs_to :qbo_account
  belongs_to :qbo_invoice, class_name: "QboInvoice", foreign_key: "qbo_invoice_id", primary_key: "qbo_id"

  validate :qbo_invoice_must_live_in_qbo_account

  def qbo_invoice
    in_memory = association(:qbo_invoice).target
    return in_memory if in_memory.present?
    return nil unless qbo_invoice_id && qbo_account_id
    QboInvoice.find_by(qbo_id: qbo_invoice_id, qbo_account_id: qbo_account_id)
  end

  def display_name
    "#{qbo_invoice.try(:display_name)}"
  end

  def status
    if qbo_invoice.nil?
      :deleted
    else
      if qbo_invoice.email_status == "EmailSent"
        overdue = (qbo_invoice.due_date - Date.today) < 0
        if qbo_invoice.balance == 0
          :paid
        elsif qbo_invoice.balance == qbo_invoice.total
          overdue ? :unpaid_overdue : :unpaid
        else
          overdue ? :partially_paid_overdue : :partially_paid
        end
      else
        :not_sent
      end
    end
  end

  def qbo_line_items_relating_to_forecast_projects(forecast_projects)
    forecast_project_ids = forecast_projects.map(&:id)
    forecast_project_codes = forecast_projects.map{|fp| fp.code}.compact.uniq

    ((qbo_invoice.try(:line_items) || []).select do |qbo_li|
      forecast_project_codes.any?{|code| (qbo_li["description"] || "").include?(code)}
    end || [])
  end

  private

  def qbo_invoice_must_live_in_qbo_account
    return if qbo_invoice_id.blank? || qbo_account_id.blank?
    return if QboInvoice.exists?(qbo_id: qbo_invoice_id, qbo_account_id: qbo_account_id)
    errors.add(:qbo_invoice_id, "no QboInvoice with qbo_id=#{qbo_invoice_id} exists in qbo_account #{qbo_account_id}")
  end
end
