require 'uri'
require 'net/http'

class Stacks::Notion
  include HTTParty
  base_uri 'https://api.notion.com/v1'

  DATABASE_IDS = {
    TASKS: "438196bedb11412eb8e737bc1bd75b2b",
    MILESTONES: "16330244ea4b424088a19d5b1987f638",
    LEADS: "4d9b46b8bad542509f144347db37964d"
  }

  def initialize()
    @headers = {
      "Authorization": "Bearer #{Stacks::Utils.config[:notion][:token]}",
      "Notion-Version" => "2021-05-13",
      "Content-Type" => "application/json"
    }
  end

  def get_users
    self.class.get("/users", headers: @headers)
  end

  def get_database(database_id)
    self.class.get("/databases/#{database_id}", headers: @headers)
  end

  def get_page(page_id)
    self.class.get("/pages/#{page_id}", headers: @headers)
  end

  def get_block_children(parent_block_id)
    self.class.get("/blocks/#{parent_block_id}/children", headers: @headers)
  end

  def create_database(parent_ref, title, properties = {})
    uri = URI("#{self.class.base_uri}/databases")
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    response = https.post(uri.path, {
      "parent" => parent_ref,
      "title" => [{
        "type": "text",
        "text": { "content": title }
      }],
      "properties" => properties
    }.to_json, @headers)
    JSON.parse(response.body)
  end

  def create_page(parent_ref, properties = {}, children = [])
    uri = URI("#{self.class.base_uri}/pages")
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    response = https.post(uri.path, {
      "parent" => parent_ref,
      "properties" => properties,
      "children" => children
    }.to_json, @headers)
    JSON.parse(response.body)
  end

  def append_block_children(parent_block_id, children)
    # Not sure why HTTParty didn't work
    uri = URI("#{self.class.base_uri}/blocks/#{parent_block_id}/children")
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    response = https.patch(uri.path, { "children" => children }.to_json, @headers)
    JSON.parse(response.body)
  end

  def query_database(database_id, start_cursor = nil)
    # Not sure why HTTParty didn't work
    uri = URI("#{self.class.base_uri}/databases/#{database_id}/query")
    https = Net::HTTP.new(uri.host, uri.port)
    https.use_ssl = true
    req = Net::HTTP::Post.new(uri.path, @headers)
    if start_cursor.present?
      req.body = {start_cursor: start_cursor}.to_json
    end
    response = https.request(req)
    JSON.parse(response.body)
  end

  def query_database_all(database_id, start_cursor = nil)
    results = []
    next_cursor = nil
    loop do
      response = query_database(database_id, next_cursor)
      results = [*results, *response["results"]]
      next_cursor = response["next_cursor"]
      break if next_cursor.nil?
    end
    results
  end

  def sync_database(database_id)
    database_entries_touched = []
    next_cursor = nil
    loop do
      response = query_database(database_id, next_cursor)
      response["results"].each do |r|
        page_title = (r.dig("properties").values.find{|v| v["type"] == "title"}.dig("title", 0, "plain_text") || "")

        r.delete("icon") # Custom icons have an AWS Expiry that break our diff
        r.delete("cover") # Cover images have an AWS Expiry that break our diff
        notion_id = r.dig("id")
        parent_type = r.dig("parent", "type")
        parent_id = r.dig("parent", parent_type)

        database_entries_touched << {
          notion_id: notion_id,
          notion_parent_type: parent_type,
          notion_parent_id: parent_id,
        }

        page =
          NotionPage.with_deleted.find_or_initialize_by(notion_id: notion_id)
        # If someone accidentally trashed this page, recover it
        page.recover! if page.deleted?
        if !page.persisted? || Hashdiff.diff(r, page.data).any?
          page.update_attributes!({
            notion_parent_type: parent_type,
            notion_parent_id: parent_id,
            data: r,
            page_title: page_title
          })
        end
      end
      next_cursor = response["next_cursor"]
      break if next_cursor.nil?
    end

    return if database_entries_touched.empty?
    NotionPage
      .where(
        notion_parent_type: database_entries_touched.first[:notion_parent_type],
        notion_parent_id: database_entries_touched.first[:notion_parent_id]
      ).where.not(
        notion_id: database_entries_touched.map{|n| n[:notion_id]}
      ).delete_all
  end
end

