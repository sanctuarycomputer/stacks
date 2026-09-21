module Mcp
  # READ: the weekly ship emails linked to a project tracker, newest first.
  # Links come from the nightly Stacks::WeeklyShips::Sweep or a human in the
  # admin; each row carries the corpus document_id so get_document can fetch
  # the full body. This is how Stacksbot reads the previous ship before
  # drafting the next one, instead of keyword-searching the corpus.
  class ListWeeklyShipsTool < MCP::Tool
    extend TrackerResolution

    DEFAULT_LIMIT = 5
    MIN_LIMIT = 1
    MAX_LIMIT = 50

    tool_name 'list_weekly_ships'
    description 'READ: weekly ship emails linked to a project tracker (by the nightly ships@ ' \
                'sweep or a human), newest first: sent_at, sender, subject, Google Groups ' \
                'permalink, and the corpus document_id to pass to get_document for the full ' \
                'body. Use it to read the previous ship before drafting the next one. Ships ' \
                'whose document was excluded from the corpus are omitted.'
    input_schema(
      properties: {
        tracker: { type: 'string', description: 'ProjectTracker id or exact name (case-insensitive). Required.' },
        limit: { type: 'integer', description: "How many ships, newest first. Default #{DEFAULT_LIMIT}, clamped to #{MIN_LIMIT}..#{MAX_LIMIT}." },
      },
      required: ['tracker']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(tracker:, limit: DEFAULT_LIMIT, server_context:)
      t = resolve_tracker(tracker)
      return unknown_tracker_error(tracker) unless t

      n = (limit.presence || DEFAULT_LIMIT).to_i.clamp(MIN_LIMIT, MAX_LIMIT)
      ships = t.weekly_ships.corpus_eligible.includes(:document).order(sent_at: :desc).limit(n)
      Responses.ok({
        tracker: t.name,
        id: t.id,
        ships: ships.map { |s| ProvisioningSerializers.weekly_ship_json(s) },
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ListWeeklyShipsTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('list_weekly_ships failed; the error was logged')
    end
  end
end
