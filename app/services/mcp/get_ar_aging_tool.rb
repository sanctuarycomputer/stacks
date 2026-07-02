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
      return QboReceivables.error_response(error) if error

      as_of = Date.today
      receivables_by_enterprise = QboReceivables.receivables(enterprises, as_of: as_of).group_by(&:enterprise_id)

      enterprise_payloads = enterprises.map do |ent|
        # Accumulate integer cents so the five buckets always sum exactly to
        # 'total' and customer totals to 'total_ar' — independent float
        # rounding can otherwise cross-foot off by a cent.
        customers = Hash.new { |h, k| h[k] = QboReceivables::BUCKETS.index_with { 0 }.merge('total' => 0) }
        (receivables_by_enterprise[ent.id] || []).each do |r|
          cents = (r.balance * 100).round
          row = customers[[r.customer_id, r.customer]]
          row[QboReceivables.bucket_key(r.days_overdue)] += cents
          row['total'] += cents
        end
        rows = customers.map do |(customer_id, customer), row|
          { 'customer' => customer, 'customer_id' => customer_id }
            .merge(row.transform_values { |cents| cents / 100.0 })
        end
        {
          enterprise: ent.name,
          customers: rows.sort_by { |r| [-r['total'], r['customer'].to_s] },
          total_ar: customers.values.sum { |row| row['total'] } / 100.0,
        }
      end

      payload = {
        as_of: as_of.iso8601,
        enterprises: enterprise_payloads,
        total_ar: enterprise_payloads.sum { |e| e[:total_ar] }.round(2),
      }
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
