module Mcp
  class ListPayableBillsTool < MCP::Tool
    tool_name 'list_payable_bills'
    description 'READ-ONLY: synced QBO vendor bills (accounts payable) per legal entity — ' \
                'vendor, doc number, total, remaining balance (reflects partial payments), ' \
                'paid state, and due date where the synced data has one. UNPAID bills only ' \
                'by default (include_paid: true adds settled ones); at most 500 bills per ' \
                'entity, flagged truncated when capped (total_outstanding still sums every ' \
                'unpaid bill). Defaults to every entity, each labeled. Figures are as of ' \
                'the last QBO bill sync; rows whose mirror has no synced data yet are ' \
                'skipped and counted.'

    # Hard payload cap per entity; total_outstanding is computed before the
    # cap so a truncated listing still reports the true unpaid sum.
    MAX_BILLS_PER_ENTITY = 500

    input_schema(
      properties: {
        entity: { type: 'string', description: 'Optional: one Enterprise name to scope to. Default: all entities.' },
        include_paid: { type: 'boolean', description: 'Include settled (fully paid) bills. Default false — unpaid only.' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(entity: nil, include_paid: false, server_context:)
      enterprises =
        if entity.present?
          ent = Enterprise.find_by(name: entity)
          unless ent
            return Responses.error("Unknown entity '#{entity}'. Valid entities: #{Enterprise.order(:name).pluck(:name).join(', ')}")
          end
          [ent]
        else
          Enterprise.order(:name).to_a
        end

      Responses.ok({
        as_of: Date.today.iso8601,
        entities: enterprises.map { |ent| entity_block(ent, include_paid: include_paid) },
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ListPayableBillsTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('list_payable_bills failed; the error was logged')
    end

    # Bills are STRICTLY read-only here: QboBill#destroy deletes the remote
    # bill in QBO (hazard H3) — nothing in this tool may write or destroy.
    # Joining through qbo_accounts (rather than Enterprise#qbo_account, a
    # has_one) covers enterprises with more than one connected QBO account.
    def self.entity_block(ent, include_paid:)
      skipped = 0
      records = QboBill.joins(:qbo_account).where(qbo_accounts: { enterprise_id: ent.id }).to_a
      vendors = vendors_for(records)

      bills = records.filter_map do |bill|
        if bill.data.blank?
          # An unsynced mirror row — QboBill#data has no lazy live fetch, but
          # there is nothing to report either. Skip and count.
          skipped += 1
          next nil
        end
        next nil if !include_paid && bill.paid?
        row = {
          vendor: vendors[[bill.qbo_account_id, bill.qbo_vendor_id]]&.display_name,
          doc_number: bill.data['doc_number'],
          total: bill.total_amount,
          remaining_balance: bill.remaining_balance,
          paid: bill.paid?,
          url: bill.qbo_url,
        }
        due_date = bill.data['due_date']
        row[:due_date] = due_date if due_date.present?
        row
      rescue StandardError => e2
        Rails.logger.warn("[Mcp::ListPayableBillsTool] skipping bill: #{e2.class}: #{e2.message}")
        Sentry.capture_exception(e2) if defined?(Sentry)
        nil
      end
      bills.sort_by! { |b| [b[:due_date] ? 0 : 1, b[:due_date].to_s, b[:doc_number].to_s] }
      {
        entity: ent.name,
        bills: bills.first(MAX_BILLS_PER_ENTITY),
        total_outstanding: bills.sum { |b| b[:paid] ? 0.0 : b[:remaining_balance].to_f }.round(2),
        skipped_count: skipped,
        truncated: bills.length > MAX_BILLS_PER_ENTITY,
      }
    end

    # One batched, realm-scoped vendor lookup per entity (the composite
    # (qbo_account_id, qbo_id) unique index serves it) instead of the
    # per-bill QboBill#vendor query. Keyed by the exact pair, so a vendor
    # qbo_id reused in another realm can never leak across accounts.
    def self.vendors_for(bills)
      with_vendor = bills.reject { |b| b.qbo_vendor_id.blank? }
      return {} if with_vendor.empty?

      QboVendor
        .where(
          qbo_account_id: with_vendor.map(&:qbo_account_id).uniq,
          qbo_id: with_vendor.map(&:qbo_vendor_id).uniq
        )
        .index_by { |v| [v.qbo_account_id, v.qbo_id] }
    end
  end
end
