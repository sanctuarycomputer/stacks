require 'uri'
require 'net/http'

class Stacks::Notion
  include HTTParty
  base_uri 'https://api.notion.com/v1'

  def initialize()
    @headers = {
      "Authorization": "Bearer #{Stacks::Utils.config[:notion][:token]}",
      "Notion-Version" => "2021-05-13",
      "Content-Type" => "application/json"
    }
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
end

