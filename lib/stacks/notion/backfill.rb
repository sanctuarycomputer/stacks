# One-off, resumable: load every page + data source the integration can see
# (properties only), then every data source schema + database object, then
# the seed page trees. Progress lives in SourceSync(:notion_backfill).cursor.
class Stacks::Notion::Backfill
  SOURCE = :notion_backfill
  DEFAULT_SEEDS = %w[329131fea2c780718aa8f222b25c76e8 dc51296819394138869baaefd534816a].freeze
  FEED_BODY = { "page_size" => 100, "sort" => { "timestamp" => "last_edited_time", "direction" => "descending" } }.freeze

  def self.run_with_lock!(client = Stacks::Notion.new, seed_ids: ENV.fetch("NOTION_SEED_PAGE_IDS", DEFAULT_SEEDS.join(",")).split(","))
    conn = ActiveRecord::Base.connection
    return nil unless conn.select_value("SELECT pg_try_advisory_lock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    begin
      new(client, seed_ids: seed_ids).run
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    end
  end

  def initialize(client, seed_ids:)
    @client = client
    @seed_ids = seed_ids.map { |s| Stacks::Notion::Ids.normalize(s) }.compact
    @stats = Hash.new(0)
  end

  def run
    sync = SourceSync.for(SOURCE)
    cursor = sync.cursor.presence || { "phase" => "feed" }
    walk_feed(sync, cursor) if cursor["phase"] == "feed"
    fetch_schemas(sync) if %w[feed schemas].include?(sync.reload.cursor["phase"])
    walk_seeds(sync)
    sync.advance!(cursor: { "phase" => "done" }, stats: @stats.transform_keys(&:to_s))
    @stats
  end

  private

  def walk_feed(sync, cursor)
    next_cursor = cursor["next_cursor"]
    loop do
      body = FEED_BODY.dup
      body["start_cursor"] = next_cursor if next_cursor
      list = @client.search(body)
      list["results"].each do |obj|
        case obj["object"]
        when "page" then Stacks::Notion::Mirror.upsert_page(obj); @stats[:pages] += 1
        when "data_source" then Stacks::Notion::Mirror.upsert_data_source(obj, fetched_at: nil); @stats[:data_sources] += 1
        end
      end
      next_cursor = list["next_cursor"]
      sync.advance!(cursor: { "phase" => "feed", "next_cursor" => next_cursor })
      break if next_cursor.nil?
    end
    sync.advance!(cursor: { "phase" => "schemas" })
  end

  def fetch_schemas(sync)
    NotionDataSource.where(fetched_at: nil).find_each do |ds|
      Stacks::Notion::Mirror.upsert_data_source(@client.get_data_source(ds.notion_id))
      if ds.database_id && !NotionDatabase.where(notion_id: ds.database_id).where.not(fetched_at: nil).exists?
        Stacks::Notion::Mirror.upsert_database(@client.get_database(ds.database_id))
      end
      @stats[:schemas] += 1
    rescue Stacks::Notion::RequestError => e
      raise unless [403, 404].include?(e.code)
      ds.update!(fetched_at: Time.current, in_trash: true)
      Rails.logger.warn("[Stacks::Notion::Backfill] data source #{ds.notion_id} inaccessible: #{e.message}")
    end
    sync.advance!(cursor: { "phase" => "seeds" })
  end

  def walk_seeds(sync)
    @seed_ids.each do |id|
      Stacks::Notion::TreeFetcher.new(@client).walk(id)
      @stats[:seeds] += 1
    rescue Stacks::Notion::RequestError => e
      Rails.logger.warn("[Stacks::Notion::Backfill] seed #{id} failed: #{e.message}")
    end
  end
end
