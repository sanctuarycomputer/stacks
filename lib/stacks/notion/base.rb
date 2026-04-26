class Stacks::Notion::Base
  attr_accessor :notion_page

  def initialize(notion_page)
    @notion_page = notion_page
  end

  def method_missing(method, *args)
    @notion_page.send method, *args
  end

  # Without this, callers using `try`, `tap`, or any code that probes via
  # respond_to? before calling a method on the delegate get a silent nil —
  # because Object#respond_to? returns false for method_missing-only methods
  # unless respond_to_missing? confirms otherwise.
  def respond_to_missing?(method_name, include_private = false)
    @notion_page.respond_to?(method_name, include_private) || super
  end

  def get_prop_value(fuzzy_key)
    fuzzy_key = fuzzy_key.downcase
    key = @notion_page.data.dig("properties").keys.find{|k| k.downcase == fuzzy_key}
    key = @notion_page.data.dig("properties").keys.find{|k| k.downcase.gsub(/[^0-9a-z ]/i, '').strip.start_with?(fuzzy_key)} unless key.present?
    return {} if key.nil?

    bearer = @notion_page.data.dig("properties", key)
    bearer.dig(bearer.dig("type"))
  end
end

