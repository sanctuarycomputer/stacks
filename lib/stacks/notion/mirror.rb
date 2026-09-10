# Upserts raw Notion objects into the mirror tables. Nothing here calls Notion.
module Stacks::Notion::Mirror
  VOLATILE_KEYS = %w[request_id request_status].freeze

  class << self
    def strip(obj)
      obj.deep_dup.tap { |o| VOLATILE_KEYS.each { |k| o.delete(k) } }
    end

    def title_of(obj)
      runs =
        if obj["object"] == "data_source" || obj["object"] == "database"
          obj["title"]
        else
          prop = (obj["properties"] || {}).values.find { |v| v.is_a?(Hash) && v["type"] == "title" }
          prop && prop["title"]
        end
      Array(runs).map { |r| r["plain_text"].to_s }.join
    end

    def upsert_page(obj, fetched_at: Time.current)
      id = Stacks::Notion::Ids.normalize(obj["id"]) or raise ArgumentError, "page id missing"
      stamp = parse_time(obj["last_edited_time"])
      parent = obj["parent"] || {}
      parent_type = parent["type"]

      # The retry must re-enter the whole transaction: a failed first-insert leaves
      # the Postgres transaction aborted, so the rescue wraps the transaction block
      # rather than living inside it.
      retry_once_on_unique_violation do
        NotionPage.transaction do
          page = NotionPage.with_deleted.lock.find_or_initialize_by(notion_id: id)
          if page.persisted? && page.notion_last_edited_at && stamp && stamp < page.notion_last_edited_at
            return page
          end

          walked = page.tree_fetched_for_edited_at
          # Under acts_as_paranoid 0.7.0, save! on a soft-deleted row never issues SQL:
          # ActiveRecord::Persistence#create_or_update returns false because the gem
          # aliases destroyed? to deleted?, so save! raises RecordNotSaved. Recover
          # first when the object is live; write a still-trashed row with update_all.
          page.recover! if page.persisted? && page.deleted? && obj["in_trash"] == false

          attrs = {
            data: strip(obj),
            page_title: title_of(obj),
            notion_parent_type: parent_type,
            notion_parent_id: parent_type == "workspace" ? nil : (Stacks::Notion::Ids.normalize(parent[parent_type]) || parent[parent_type]),
            database_id: Stacks::Notion::Ids.normalize(parent["database_id"]),
            data_source_id: Stacks::Notion::Ids.normalize(parent["data_source_id"]),
            notion_last_edited_at: stamp,
            page_fetched_at: fetched_at,
            in_trash: obj["in_trash"] == true,
            access_lost: false,
            url: obj["url"]
          }
          attrs[:blocks_stale_at] = page.blocks_stale_at || fetched_at if walked && stamp && walked != stamp

          if page.persisted? && page.deleted?
            NotionPage.with_deleted.where(id: page.id).update_all(attrs)
            NotionPage.with_deleted.find(page.id)
          else
            page.assign_attributes(attrs)
            page.save!
            page
          end
        end
      end
    end

    def upsert_data_source(obj, fetched_at: Time.current)
      id = Stacks::Notion::Ids.normalize(obj["id"]) or raise ArgumentError, "data source id missing"
      retry_once_on_unique_violation do
        row = NotionDataSource.find_or_initialize_by(notion_id: id)
        row.assign_attributes(
          data: strip(obj), title: title_of(obj),
          database_id: Stacks::Notion::Ids.normalize(obj.dig("parent", "database_id")),
          notion_last_edited_at: parse_time(obj["last_edited_time"]),
          in_trash: obj["in_trash"] == true
        )
        # A feed-sourced object (fetched_at: nil) must not clear a fetched_at learned
        # from GET /data_sources/:id — the backfill relies on nil meaning "schema not fetched".
        row.fetched_at = fetched_at if fetched_at || row.new_record?
        row.save!
        row
      end
    end

    def upsert_database(obj, fetched_at: Time.current)
      id = Stacks::Notion::Ids.normalize(obj["id"]) or raise ArgumentError, "database id missing"
      retry_once_on_unique_violation do
        row = NotionDatabase.find_or_initialize_by(notion_id: id)
        row.update!(
          data: strip(obj), title: title_of(obj),
          notion_last_edited_at: parse_time(obj["last_edited_time"]),
          fetched_at: fetched_at, in_trash: obj["in_trash"] == true
        )
        row
      end
    end

    # Full level replace: rows not in `blocks` are deleted, the rest upserted by
    # notion_id with parent_id/position updated in place (a moved block never
    # collides on the unique index). Stamps the level marker.
    def replace_level(parent_id:, page_id:, blocks:, fetched_at: Time.current)
      parent_id = Stacks::Notion::Ids.normalize(parent_id) || parent_id
      page_id = Stacks::Notion::Ids.normalize(page_id) || page_id
      NotionBlock.transaction do
        rows = store_blocks(parent_id: parent_id, page_id: page_id, blocks: blocks, position_offset: 0)
        NotionBlock.where(parent_id: parent_id).where.not(notion_id: rows.map(&:notion_id)).delete_all
        if parent_id == page_id
          NotionPage.with_deleted.where(notion_id: page_id).update_all(root_children_fetched_at: fetched_at)
        else
          NotionBlock.where(notion_id: parent_id).update_all(children_fetched_at: fetched_at)
        end
        rows
      end
    end

    def store_blocks(parent_id:, page_id:, blocks:, position_offset: 0)
      parent_id = Stacks::Notion::Ids.normalize(parent_id) || parent_id
      page_id = Stacks::Notion::Ids.normalize(page_id) || page_id
      blocks.each_with_index.map do |obj, i|
        bid = Stacks::Notion::Ids.normalize(obj["id"]) || obj["id"]
        retry_once_on_unique_violation do
          row = NotionBlock.find_or_initialize_by(notion_id: bid)
          row.update!(parent_id: parent_id, page_id: page_id, position: position_offset + i,
                      has_children: obj["has_children"] == true, data: strip(obj))
          row
        end
      end
    end

    def owning_page_id(id)
      norm = Stacks::Notion::Ids.normalize(id) || id
      return norm if NotionPage.with_deleted.where(notion_id: norm).exists?
      NotionBlock.where(notion_id: norm).pick(:page_id)
    end

    private

    # Two writers (Puma threads serving the proxy, the sweep rake process) can race
    # to insert the same notion_id for the first time. find_or_initialize_by only
    # locks an existing row, so the loser's INSERT hits the unique index and raises
    # RecordNotUnique. Rescue once and retry: the retry's lookup finds the row the
    # winner just created.
    def retry_once_on_unique_violation
      yield
    rescue ActiveRecord::RecordNotUnique
      yield
    end

    def parse_time(str)
      str.present? ? Time.zone.parse(str) : nil
    end
  end
end
