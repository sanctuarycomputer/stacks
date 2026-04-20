class DeelInvoiceAdjustments::SyncFromDeel
  REMOVED_REMOTE_HTTP_CODES = [403, 404].freeze

  def self.call(deel_invoice_adjustment)
    parsed = Stacks::Deel.get_invoice_adjustment!(deel_invoice_adjustment.deel_adjustment_id)
    attrs = DeelInvoiceAdjustment.attributes_from_deel_api_payload(parsed)
    deel_invoice_adjustment.update!(
      attrs.merge(synced_at: Time.current),
    )
    deel_invoice_adjustment
  rescue Stacks::Deel::ApiError => e
    raise unless remote_gone?(e)

    Rails.logger.warn(
      "[DeelInvoiceAdjustments::SyncFromDeel] soft-deleting adjustment id=#{deel_invoice_adjustment.id} " \
      "deel_adjustment_id=#{deel_invoice_adjustment.deel_adjustment_id} http=#{e.http_code} msg=#{e.message.truncate(200)}",
    )
    deel_invoice_adjustment.destroy!
    :removed
  end

  def self.remote_gone?(error)
    REMOVED_REMOTE_HTTP_CODES.include?(error.http_code)
  end
end
