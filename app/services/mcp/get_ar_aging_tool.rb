module Mcp
  class GetArAgingTool < MCP::Tool
    tool_name 'get_ar_aging'
    description 'AR aging buckets (current = not yet due, then 1-30/31-60/61-90/over-90 days ' \
                'overdue) per customer per enterprise, computed from already-synced QBO ' \
                'invoices. Never calls QBO live.'
    input_schema(
      properties: {
        enterprise: { type: 'string', description: 'Optional enterprise name filter, e.g. "Sanctuary Computer Inc"' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(enterprise: nil, server_context:)
      enterprises, error = QboReceivables.resolve_enterprises(enterprise)
      return Responses.error(error) if error

      as_of = Date.today
      receivables_by_enterprise = QboReceivables.receivables(enterprises, as_of: as_of).group_by(&:enterprise_id)

      grand_total_cents = 0
      enterprise_payloads = enterprises.map do |ent|
        # Accumulate integer cents so every emitted value is a decimal-exact
        # cent amount and buckets sum to 'total' exactly in decimal. (A
        # consumer re-summing the parsed IEEE doubles can still see epsilon
        # artifacts like 0.1 + 0.2 — inherent to JSON numbers, not to this
        # report.) Grouping semantics live on Receivable#customer_key.
        grouped = (receivables_by_enterprise[ent.id] || []).group_by(&:customer_key)
        total_cents = 0
        rows = grouped.map do |_key, rs|
          representative = rs.max_by(&:due_date)
          bucket_row = QboReceivables::BUCKETS.index_with { 0 }.merge('total' => 0)
          rs.each do |r|
            cents = (r.balance * 100).round
            bucket_row[QboReceivables.bucket_key(r.days_overdue)] += cents
            bucket_row['total'] += cents
          end
          total_cents += bucket_row['total']
          { 'customer' => representative.customer || 'Unknown', 'customer_id' => representative.customer_id.presence }
            .merge(bucket_row.transform_values { |cents| cents / 100.0 })
        end
        grand_total_cents += total_cents
        {
          enterprise: ent.name,
          customers: rows.sort_by { |r| [-r['total'], r['customer'].to_s] },
          total_ar: total_cents / 100.0,
        }
      end

      payload = {
        as_of: as_of.iso8601,
        enterprises: enterprise_payloads,
        total_ar: grand_total_cents / 100.0,
      }
      Responses.ok(payload)
    end
  end
end
