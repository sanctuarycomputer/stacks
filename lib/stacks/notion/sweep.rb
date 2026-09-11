# Every 10 minutes: walk Notion's search feed (newest first) back to the last
# watermark, upsert what changed, then refresh stale block trees until the run
# deadline. Search returns full page objects, so properties cost 1–3 requests.
class Stacks::Notion::Sweep
  # Shared by Sweep, Backfill and Reconcile — they are mutually exclusive.
  ADVISORY_LOCK_KEY = 728534292
  SOURCE = :notion_mirror

  def self.run_with_lock!(client = Stacks::Notion.new)
    conn = ActiveRecord::Base.connection
    return nil unless conn.select_value("SELECT pg_try_advisory_lock(#{ADVISORY_LOCK_KEY})")
    begin
      new(client).run
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{ADVISORY_LOCK_KEY})")
    end
  end

  def initialize(client, now: Time.current, run_deadline: 5.minutes, recheck_limit: 50,
                 overlap: Integer(ENV.fetch("NOTION_SWEEP_OVERLAP", 300)).seconds)
    @client = client
    @now = now
    @run_deadline = run_deadline
    @recheck_limit = recheck_limit
    @overlap = overlap
    @stats = Hash.new(0)
  end

  def run
    sync = SourceSync.for(SOURCE)
    watermark = sync.cursor["watermark"].present? ? Time.zone.parse(sync.cursor["watermark"]) : nil
    newest = walk_feed(watermark)
    recheck!
    refresh_trees!
    new_watermark = [newest, @now].compact.min
    @stats[:watermark] = new_watermark&.utc&.iso8601
    sync.advance!(cursor: { "watermark" => @stats[:watermark] }, stats: @stats.transform_keys(&:to_s))
    @stats
  end

  private

  def walk_feed(watermark)
    floor = watermark && (watermark - @overlap)
    seen = Set.new
    newest = nil
    cursor = nil
    loop do
      body = { "page_size" => 100, "sort" => { "timestamp" => "last_edited_time", "direction" => "descending" } }
      body["start_cursor"] = cursor if cursor
      list = @client.search(body)
      @stats[:feed_requests] += 1
      @stats[:requests_spent] += 1
      stop = false
      list["results"].each do |obj|
        stamp = Time.zone.parse(obj["last_edited_time"].to_s)
        newest = [newest, stamp].compact.max
        if floor && stamp && stamp < floor
          stop = true
          break
        end
        next unless seen.add?(obj["id"])
        case obj["object"]
        when "page"
          Stacks::Notion::Mirror.upsert_page(obj, fetched_at: @now)
          @stats[:pages_upserted] += 1
        when "data_source"
          Stacks::Notion::Mirror.upsert_data_source(obj, fetched_at: @now)
          @stats[:data_sources_upserted] += 1
        end
      end
      cursor = list["next_cursor"]
      break if stop || cursor.nil?
    end
    newest
  end

  # Pages whose tree was walked within a minute of their edit stamp: re-read
  # the page object once so a same-minute edit is not missed.
  def recheck!
    NotionPage.where("recheck_after <= ?", @now).order(:recheck_after).limit(@recheck_limit).each do |page|
      obj = @client.get_page(page.notion_id)
      @stats[:requests_spent] += 1
      @stats[:rechecks] += 1
      Stacks::Notion::Mirror.upsert_page(obj, fetched_at: @now) # marks stale if the stamp moved
      NotionPage.with_deleted.where(id: page.id).update_all(recheck_after: nil)
    rescue Stacks::Notion::RequestError => e
      Rails.logger.warn("[Stacks::Notion::Sweep] recheck #{page.notion_id} failed: #{e.message}")
      NotionPage.with_deleted.where(id: page.id).update_all(recheck_after: nil)
    end
  end

  def refresh_trees!
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    candidates = NotionPage.where.not(wanted_at: nil).order(:wanted_at).to_a +
                 NotionPage.where(wanted_at: nil).where.not(blocks_stale_at: nil).where.not(root_children_fetched_at: nil).order(notion_last_edited_at: :desc).to_a
    candidates.uniq(&:id).each do |page|
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= @run_deadline
        @stats[:pages_still_stale] += 1
        next
      end
      result = Stacks::Notion::TreeFetcher.new(@client).walk(page.notion_id)
      @stats[:requests_spent] += result[:requests]
      if result[:complete]
        @stats[:trees_refreshed] += 1
      else
        @stats[:pages_still_stale] += 1
      end
    rescue Stacks::Notion::RequestError => e
      Rails.logger.warn("[Stacks::Notion::Sweep] tree #{page.notion_id} failed: #{e.message}")
      @stats[:pages_still_stale] += 1
    end
  end
end
