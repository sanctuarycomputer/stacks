module Mcp
  # READ: the weekly ship emails linked to a project tracker, newest first.
  # Links come from the nightly Stacks::WeeklyShips::Sweep or a human in the
  # admin; each row carries the corpus document_id so get_document can fetch
  # the full body. This is how Stacksbot reads the previous ship before
  # drafting the next one, instead of keyword-searching the corpus.
  class ListWeeklyShipsTool < MCP::Tool
    extend TrackerResolution

    DEFAULT_LIMIT = 5
    MAX_LIMIT = 50

    tool_name 'list_weekly_ships'
    description 'READ: weekly ship emails linked to a project tracker (by the nightly ships@ ' \
                'sweep or a human), newest first: sent_at, sender, subject, Google Groups ' \
                'permalink, and the corpus document_id to pass to get_document for the full ' \
                'body. Use it to read the previous ship before drafting the next one.'
    input_schema(
      properties: {
        tracker: { type: 'string', description: 'ProjectTracker id or exact name (case-insensitive). Required.' },
        limit: { type: 'integer', description: "How many ships, newest first. Default #{DEFAULT_LIMIT}, max #{MAX_LIMIT}." },
      },
      required: ['tracker']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(tracker:, limit: DEFAULT_LIMIT, server_context:)
      t = resolve_tracker(tracker)
      return unknown_tracker_error(tracker) unless t

      n = [[limit.to_i, 1].max, MAX_LIMIT].min
      ships = t.weekly_ships.includes(:document).order(sent_at: :desc).limit(n)
      Responses.ok({
        tracker: t.name,
        id: t.id,
        ships: ships.map { |s| ship_json(s) },
      })
    rescue StandardError => e
      Rails.logger.warn("[Mcp::ListWeeklyShipsTool] #{e.class}: #{e.message}")
      Sentry.capture_exception(e) if defined?(Sentry)
      Responses.error('list_weekly_ships failed; the error was logged')
    end

    # Shared with get_project_burnup's last_weekly_ship.
    def self.ship_json(ship)
      return nil if ship.nil?
      doc = ship.document
      {
        id: ship.id,
        document_id: doc&.id,
        subject: doc&.title,
        sent_at: ship.sent_at,
        sent_by: ship.sent_by_name.presence || ship.sent_by_email,
        url: doc&.google_groups_permalink,
        matched_by: ship.matched_by,
        confidence: ship.confidence,
      }
    end
  end
end
