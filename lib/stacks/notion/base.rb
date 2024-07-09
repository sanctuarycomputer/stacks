class Stacks::Notion::Base
  attr_accessor :notion_page

  def initialize(notion_page)
    @notion_page = notion_page
  end

  def method_missing(method, *args)
    @notion_page.send method, *args
  end

  def get_prop_value(fuzzy_key)
    key = @notion_page.data.dig("properties").keys.find{|k| k.downcase == fuzzy_key}
    key = @notion_page.data.dig("properties").keys.find{|k| k.downcase.include?(fuzzy_key)} unless key.present?
    return {} if key.nil?

    bearer = @notion_page.data.dig("properties", key)
    bearer.dig(bearer.dig("type"))
  end
end

