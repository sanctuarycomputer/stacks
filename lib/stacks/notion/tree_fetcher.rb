# Fills and refreshes a page's block tree level by level (every cursor page of a
# level in one go), under an optional wall-clock deadline. Idempotent and
# resumable: only levels whose marker is missing or older than blocks_stale_at
# are fetched, so a walk cut short by the deadline continues on the next call.
class Stacks::Notion::TreeFetcher
  MINUTE_GUARD = 60.seconds

  def self.fetch_level(client, parent_id:, page_id:)
    blocks = []
    cursor = nil
    requests = 0
    loop do
      list = client.get_block_children(parent_id, start_cursor: cursor, page_size: 100)
      requests += 1
      blocks.concat(list["results"])
      cursor = list["next_cursor"]
      break if cursor.nil?
    end
    [blocks, requests]
  end

  def initialize(client, deadline: nil)
    @client = client
    @deadline = deadline
    @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @requests = 0
  end

  def walk(page_id)
    # Reset per-walk counters: @requests/@started are set in initialize, so a
    # second walk on the same instance would otherwise report a cumulative
    # request count against an already-spent deadline.
    @requests = 0
    @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    page_id = Stacks::Notion::Ids.normalize(page_id) || page_id
    page = NotionPage.with_deleted.find_by(notion_id: page_id) || fetch_page!(page_id)

    # A completed tree stamped for the page's current edit, with no
    # invalidation pending (no staleness marker, no outstanding want), is
    # fresh by construction: nothing in the tree can be stale, so skip the
    # DB walk entirely rather than pay two indexed queries per has_children
    # block on every call.
    if page.blocks_stale_at.nil? && page.wanted_at.nil? &&
       page.tree_fetched_for_edited_at.present? &&
       page.tree_fetched_for_edited_at == page.notion_last_edited_at
      return { complete: true, requests: @requests }
    end

    stamp_at_start = page.notion_last_edited_at
    walk_started_at = Time.current
    stale_at = page.blocks_stale_at

    queue = [page_id]
    until queue.empty?
      parent_id = queue.shift
      if level_stale?(page, parent_id, stale_at)
        blocks, n = self.class.fetch_level(@client, parent_id: parent_id, page_id: page_id)
        @requests += n
        Stacks::Notion::Mirror.replace_level(parent_id: parent_id, page_id: page_id, blocks: blocks, fetched_at: Time.current)
        enqueue_children!(queue, parent_id)
        # Checked AFTER the level so every walk makes progress; the next call
        # resumes because fresh levels are skipped.
        return give_up(page) if expired? && queue.any?
        next
      end
      enqueue_children!(queue, parent_id)
    end

    refresh_page_stamp!(page) if stamp_at_start.nil?
    page.reload
    if page.notion_last_edited_at != stamp_at_start && !stamp_at_start.nil?
      update_page!(page, blocks_stale_at: page.blocks_stale_at || Time.current)
      return { complete: false, requests: @requests }
    end

    attrs = { tree_fetched_for_edited_at: page.notion_last_edited_at, blocks_stale_at: nil, wanted_at: nil }
    if page.notion_last_edited_at && walk_started_at < page.notion_last_edited_at + MINUTE_GUARD
      attrs[:recheck_after] = page.notion_last_edited_at + MINUTE_GUARD
    end
    update_page!(page, attrs)
    { complete: true, requests: @requests }
  end

  private

  def enqueue_children!(queue, parent_id)
    NotionBlock.where(parent_id: parent_id, has_children: true).order(:position).pluck(:notion_id).each { |id| queue << id }
  end

  # update_all through with_deleted: `update!` on a soft-deleted row raises
  # RecordNotSaved under acts_as_paranoid 0.7 (default scope matches 0 rows).
  def update_page!(page, attrs)
    NotionPage.with_deleted.where(id: page.id).update_all(attrs)
  end

  def fetch_page!(page_id)
    obj = @client.get_page(page_id)
    @requests += 1
    Stacks::Notion::Mirror.upsert_page(obj)
  end

  # Re-read the page object (1 request) so a stamp learned mid-walk is current.
  def refresh_page_stamp!(page)
    obj = @client.get_page(page.notion_id)
    @requests += 1
    Stacks::Notion::Mirror.upsert_page(obj)
    true
  end

  def level_stale?(page, parent_id, stale_at)
    marker =
      if parent_id == page.notion_id
        page.root_children_fetched_at
      else
        NotionBlock.where(notion_id: parent_id).pick(:children_fetched_at)
      end
    marker.nil? || (stale_at && marker < stale_at)
  end

  def expired?
    @deadline && (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started) >= @deadline
  end

  def give_up(page)
    update_page!(page, wanted_at: page.wanted_at || Time.current)
    { complete: false, requests: @requests }
  end
end
