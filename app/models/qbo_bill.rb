class QboBill < ApplicationRecord
  self.primary_key = "qbo_id"
  belongs_to :qbo_vendor, class_name: "QboVendor", foreign_key: "qbo_vendor_id", primary_key: "qbo_id"

  before_destroy :delete_qbo_bill!

  def qbo_url
    "https://qbo.intuit.com/app/bill?&txnId=#{qbo_id}"
  end

  def delete_qbo_bill!
    begin
      Stacks::Quickbooks.delete_bill(Stacks::Quickbooks.fetch_bill_by_id(qbo_id))
    rescue => e
      if e.message.starts_with?("Object Not Found:")
        return nil
      end
      raise e
    end
  end
end
