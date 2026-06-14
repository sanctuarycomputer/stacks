module Money
  # Bulk-refresh: walks the rows PayableQboBills would return and calls
  # SyncsAsQboBill#sync_qbo_bill! on each so bills marked Paid in QBO drop
  # off the page on the next render.
  class RefreshPayableQboBills
    def self.call(qbo_account:)
      Money::PayableQboBills.call(qbo_account: qbo_account).each do |row|
        row.host.sync_qbo_bill!
      end
    end
  end
end
