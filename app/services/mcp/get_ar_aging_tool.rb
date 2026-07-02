module Mcp
  class GetArAgingTool < MCP::Tool
    tool_name 'get_ar_aging'
    description 'AR aging buckets (current/0-30/31-60/61-90/90+ days overdue) per customer ' \
                'per enterprise, computed from already-synced QBO invoices. Never calls QBO live.'
    input_schema(
      properties: {
        enterprise: { type: 'string', description: 'Optional enterprise name filter, e.g. "Sanctuary Computer Inc"' },
      },
      required: []
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    BUCKETS = %w[current days_0_30 days_31_60 days_61_90 days_90_plus].freeze

    def self.call(enterprise: nil, server_context:)
      enterprises, error = QboReceivables.resolve_enterprises(enterprise)
      return QboReceivables.error_response(error) if error

      as_of = Date.today
      enterprise_payloads = enterprises.map do |ent|
        customers = Hash.new { |h, k| h[k] = BUCKETS.index_with { 0.0 }.merge('total' => 0.0) }
        QboReceivables.receivables(ent).each do |inv|
          bucket = QboReceivables.bucket_key(QboReceivables.days_overdue(inv, as_of))
          row = customers[inv.customer_ref['name'] || 'Unknown']
          row[bucket] += inv.balance
          row['total'] += inv.balance
        rescue StandardError
          next # malformed synced row — skip it, never fail the whole report
        end
        rows = customers.map do |name, row|
          { 'customer' => name }.merge(row.transform_values { |v| v.round(2) })
        end
        {
          enterprise: ent.name,
          customers: rows.sort_by { |r| [-r['total'], r['customer'].to_s] },
          total_ar: rows.sum { |r| r['total'] }.round(2),
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
