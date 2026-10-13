# Reads properties off a raw Notion page hash (what the API returns and what
# notion_pages.data stores). The rows are written by Stacksbot and edited by
# people, so every reader here returns an empty value for anything missing or
# misshapen and none of them raises.
module Stacks::Notion::Props
  module_function

  def top(data, key)
    data.is_a?(Hash) ? data[key] : nil
  end

  # The value under the property's own type key, or nil.
  def value(data, name, type)
    props = top(data, "properties")
    prop = props.is_a?(Hash) ? props[name] : nil
    prop.is_a?(Hash) ? prop[type] : nil
  end

  # Reads a select. Falls back to the "status" key, so a property that is
  # later turned into a Notion status does not start reading as blank.
  def select(data, name)
    v = value(data, name, "select")
    v = value(data, name, "status") unless v.is_a?(Hash)
    name_of = v.is_a?(Hash) ? v["name"] : nil
    name_of.is_a?(String) ? name_of.strip.presence : nil
  end

  def text(data, name, type = "rich_text")
    v = value(data, name, type)
    return "" unless v.is_a?(Array)
    v.map { |f| f.is_a?(Hash) && f["plain_text"].is_a?(String) ? f["plain_text"] : "" }.join.strip
  end

  def url(data, name)
    http_url(value(data, name, "url"))
  end

  # Only a web address is ever linked: a stored "javascript:" would run.
  def http_url(v)
    v.is_a?(String) && v.match?(%r{\Ahttps?://\S+\z}i) ? v : nil
  end

  def time(data, name)
    v = value(data, name, "date")
    parse_time(v.is_a?(Hash) ? v["start"] : nil)
  end

  def parse_time(v)
    return nil unless v.is_a?(String) && v.present?
    Time.zone.parse(v)
  rescue ArgumentError
    nil
  end

  def relation_ids(data, name)
    v = value(data, name, "relation")
    return [] unless v.is_a?(Array)
    v.filter_map { |r| r["id"] if r.is_a?(Hash) && r["id"].is_a?(String) && r["id"].present? }.uniq
  end

  # Notion sends the first 25 of a longer relation and sets has_more.
  def relation_truncated?(data, name)
    props = top(data, "properties")
    prop = props.is_a?(Hash) ? props[name] : nil
    prop.is_a?(Hash) && prop["has_more"] == true
  end

  def number(data, name)
    v = value(data, name, "number")
    v.is_a?(Numeric) ? v : nil
  end

  # The text a formula gives, trimmed: "" when the formula's result is empty.
  # nil when the page has no such property or it is not a text formula, which
  # is "Notion does not say" and not the same as an empty answer.
  def formula_text(data, name)
    formula = value(data, name, "formula")
    return nil unless formula.is_a?(Hash) && formula["type"] == "string"
    formula["string"].is_a?(String) ? formula["string"].strip : ""
  end

  # A yes or no that Notion states, from a checkbox or from a formula whose
  # result is a boolean (an empty result reads as false). nil when the page
  # has no such property or it is of another shape.
  def boolean(data, name)
    checkbox = value(data, name, "checkbox")
    return checkbox if checkbox == true || checkbox == false
    formula = value(data, name, "formula")
    return formula["boolean"] == true if formula.is_a?(Hash) && formula["type"] == "boolean"
    nil
  end

  # Whether a page is flagged, from a property that is either a text formula
  # (flagged when it gives any text, which is the reason) or a yes/no (a
  # boolean formula or a checkbox). true or false when Notion states it, nil
  # when the page has no such property or it is of another shape.
  # Its SQL twin is Stacks::ProjectLog.stated_flag_sql.
  def flagged(data, name)
    text = formula_text(data, name)
    text.nil? ? boolean(data, name) : text.present?
  end

  def people_names(data, name)
    v = value(data, name, "people")
    return [] unless v.is_a?(Array)
    v.filter_map { |p| p["name"].strip.presence if p.is_a?(Hash) && p["name"].is_a?(String) }
  end
end
