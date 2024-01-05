class AdhocInvoiceTracker < ApplicationRecord
  belongs_to :project_tracker
  belongs_to :qbo_invoice, class_name: "QboInvoice", foreign_key: "qbo_invoice_id", primary_key: "qbo_id"

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
end
