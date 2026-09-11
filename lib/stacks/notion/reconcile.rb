# Daily: full feed walk; anything cached that the feed no longer returns gets
# one GET to tell "trashed" from "lost access". Reports sweep drift.
class Stacks::Notion::Reconcile
  FEED_BODY = Stacks::Notion::Backfill::FEED_BODY

  def self.run_with_lock!(client = Stacks::Notion.new, disambiguation_limit: 200)
    conn = ActiveRecord::Base.connection
    return nil unless conn.select_value("SELECT pg_try_advisory_lock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    begin
      new(client, disambiguation_limit: disambiguation_limit).run
    ensure
      conn.execute("SELECT pg_advisory_unlock(#{Stacks::Notion::Sweep::ADVISORY_LOCK_KEY})")
    end
  end

  def initialize(client, disambiguation_limit: 200)
    @client = client
    @limit = disambiguation_limit
  end

  def run
    before = NotionPage.pluck(:notion_id, :notion_last_edited_at).to_h
    seen_pages = {}
    seen_ds = Set.new
    cursor = nil
    loop do
      body = FEED_BODY.dup
      body["start_cursor"] = cursor if cursor
      list = @client.search(body)
      list["results"].each do |obj|
        id = Stacks::Notion::Ids.normalize(obj["id"])
        case obj["object"]
        when "page"
          Stacks::Notion::Mirror.upsert_page(obj) # feed objects are full: brings drifted rows current
          seen_pages[id] = Time.zone.parse(obj["last_edited_time"].to_s)
        when "data_source"
          Stacks::Notion::Mirror.upsert_data_source(obj, fetched_at: nil)
          seen_ds << id
        end
      end
      cursor = list["next_cursor"]
      break if cursor.nil?
    end

    drift = seen_pages.count { |id, stamp| before.key?(id) && (before[id].nil? || (stamp && before[id] < stamp)) }
    stats = { seen: seen_pages.size, checked: 0, trashed: 0, access_lost: 0, drift: drift }

    NotionPage.where(in_trash: false, access_lost: false).where.not(notion_id: seen_pages.keys)
              .order(:notion_last_edited_at).limit(@limit).each do |page|
      stats[:checked] += 1
      obj = @client.get_page(page.notion_id)
      Stacks::Notion::Mirror.upsert_page(obj)
      stats[:trashed] += 1 if obj["in_trash"] == true
    rescue Stacks::Notion::RequestError => e
      raise unless [403, 404].include?(e.code)
      page.update!(access_lost: true)
      stats[:access_lost] += 1
    end

    NotionDataSource.where(in_trash: false).where.not(notion_id: seen_ds.to_a)
                    .order(:notion_last_edited_at).limit([@limit - stats[:checked], 0].max).each do |ds|
      stats[:checked] += 1
      obj = @client.get_data_source(ds.notion_id)
      Stacks::Notion::Mirror.upsert_data_source(obj)
      stats[:trashed] += 1 if obj["in_trash"] == true
    rescue Stacks::Notion::RequestError => e
      raise unless [403, 404].include?(e.code)
      ds.update!(in_trash: true)
      stats[:access_lost] += 1
    end
    stats
  end
end
