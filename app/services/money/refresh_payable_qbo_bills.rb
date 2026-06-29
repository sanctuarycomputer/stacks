module Money
  # Bulk-refresh: walks the rows PayableQboBills would return and calls
  # SyncsAsQboBill#sync_qbo_bill! on each so bills marked Paid in QBO drop
  # off the page on the next render.
  #
  # Per-row rescue: a single host that raises (QBO 5xx, missing vendor mapping,
  # validation, expired auth) must NOT abort the rest of the batch. We log and
  # continue; admins still see the unrecovered rows on the next page render and
  # can drill into each one individually.
  class RefreshPayableQboBills
    def self.call(qbo_account:)
      failures = []
      Money::PayableQboBills.call(qbo_account: qbo_account).each do |row|
        begin
          row.host.sync_qbo_bill!
        rescue => e
          failures << [row.host, e]
          Rails.logger.error("[refresh_payable_qbo_bills] qbo_account=#{qbo_account.id} host=#{row.host.class.name}##{row.host.id}: #{e.class}: #{e.message}")
        end
      end
      failures
    end
  end
end
