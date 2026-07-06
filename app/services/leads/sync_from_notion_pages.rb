module Leads
  # Projects NotionPage lead rows into notion_leads(+studios) so lead
  # datapoints are computable without parsing jsonb per request. Field
  # extraction goes through the existing Stacks::Notion::Lead accessors —
  # they stay the single source of truth for Notion property names. Full
  # rebuild each run (hundreds of rows); per-row failures warn and skip so
  # one malformed page can't sink the rebuild.
  class SyncFromNotionPages
    def self.call
      pages = NotionPage.lead.to_a

      ActiveRecord::Base.transaction do
        NotionLeadStudio.delete_all
        NotionLead.delete_all

        pages.each do |page|
          # Savepoint per page: a Postgres-level error (unique/FK/not-null
          # violation) would otherwise mark the outer transaction aborted,
          # making every later page fail with "current transaction is
          # aborted" — silently sinking the rebuild. Rolling back just the
          # savepoint keeps the outer transaction healthy, and also drops any
          # partial rows (a lead missing some studio links) atomically.
          ActiveRecord::Base.transaction(requires_new: true) do
            lead = page.as_lead
            row = NotionLead.create!(
              notion_page_id: page.id,
              received_at: parse_date(page, :received_at, lead.received_at),
              settled_at: parse_date(page, :settled_at, lead.settled_at),
              proposal_sent_at: parse_date(page, :proposal_sent_at, lead.proposal_sent_at),
              won_at: parse_date(page, :won_at, lead.won_at),
            )
            lead.studios.each do |studio|
              NotionLeadStudio.create!(notion_lead: row, studio: studio)
            end
          end
        rescue StandardError => e
          Rails.logger.warn(
            "[Leads::SyncFromNotionPages] skipping notion_page=#{page.id}: #{e.class} #{e.message}"
          )
        end
      end
    end

    def self.parse_date(page, attr, raw)
      return nil if raw.blank?
      Date.parse(raw.to_s)
    rescue Date::Error
      Rails.logger.warn(
        "[Leads::SyncFromNotionPages] unparseable #{attr}=#{raw.inspect} on notion_page=#{page.id}"
      )
      nil
    end
  end
end
