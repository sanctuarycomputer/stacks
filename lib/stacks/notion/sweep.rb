# Every 10 minutes: walk Notion's search feed (newest first) back to the last
# watermark, upsert what changed, then refresh stale block trees until the run
# deadline. Search returns full page objects, so properties cost 1–3 requests.
class Stacks::Notion::Sweep
  # Shared by Sweep, Backfill and Reconcile — they are mutually exclusive.
  ADVISORY_LOCK_KEY = 728534292
  SOURCE = :notion_mirror

  # The run deadline bounds how much work a single run does; this bounds how
  # much memory a single run uses. Anything beyond the cap is picked up next
  # run (candidates are ordered oldest-want/stalest-first, so nothing starves).
  REFRESH_CANDIDATE_CAP = 500

  # First ever run (or a cleared watermark row) has no floor, so an unbounded
  # walk would pull the entire workspace through the feed. Cap it — the
  # backfill task owns loading full history; the sweep just needs a recent
  # watermark to start incremental walks from.
  FIRST_RUN_FEED_PAGES = 5

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
    %i[feed_requests pages_upserted data_sources_upserted rechecks trees_refreshed pages_still_stale pages_access_lost requests_spent].each { |k| @stats[k] = 0 }
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
    if watermark.nil?
      Rails.logger.info("[Stacks::Notion::Sweep] no watermark yet; capping first-run feed walk at #{FIRST_RUN_FEED_PAGES} pages — the backfill task owns the full load")
    end
    seen = Set.new
    newest = nil
    cursor = nil
    pages_walked = 0
    loop do
      body = { "page_size" => 100, "sort" => { "timestamp" => "last_edited_time", "direction" => "descending" } }
      body["start_cursor"] = cursor if cursor
      list = @client.search(body)
      pages_walked += 1
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
      stop ||= watermark.nil? && pages_walked >= FIRST_RUN_FEED_PAGES
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
    candidates = NotionPage.where(in_trash: false, access_lost: false).where.not(wanted_at: nil)
                           .select(:id, :notion_id, :wanted_at, :notion_last_edited_at).order(:wanted_at).limit(REFRESH_CANDIDATE_CAP).to_a +
                 NotionPage.where(in_trash: false, access_lost: false, wanted_at: nil).where.not(blocks_stale_at: nil).where.not(root_children_fetched_at: nil)
                           .select(:id, :notion_id, :wanted_at, :notion_last_edited_at).order(notion_last_edited_at: :desc).limit(REFRESH_CANDIDATE_CAP).to_a
    candidates.uniq(&:id).each do |page|
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= @run_deadline
        @stats[:pages_still_stale] += 1
        next
      end
      remaining = @run_deadline.to_f - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      result = Stacks::Notion::TreeFetcher.new(@client, deadline: remaining).walk(page.notion_id)
      @stats[:requests_spent] += result[:requests]
      if result[:complete]
        @stats[:trees_refreshed] += 1
      else
        @stats[:pages_still_stale] += 1
      end
    rescue Stacks::Notion::RequestError => e
      if [403, 404].include?(e.code)
        NotionPage.with_deleted.where(id: page.id).update_all(access_lost: true, wanted_at: nil, blocks_stale_at: nil)
        @stats[:pages_access_lost] += 1
        Rails.logger.warn("[Stacks::Notion::Sweep] tree #{page.notion_id} access lost: #{e.message}")
      else
        Rails.logger.warn("[Stacks::Notion::Sweep] tree #{page.notion_id} failed: #{e.message}")
        @stats[:pages_still_stale] += 1
      end
    end
  end
end
