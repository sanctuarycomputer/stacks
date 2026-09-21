class ProjectTrackerLink < ApplicationRecord
  belongs_to :project_tracker
  validates :name, presence: :true
  # Anchored: the URL must BE an http(s) URL with a host, not merely contain
  # one (URI::regexp matched "javascript:alert(1)//https://x"). These render as
  # clickable pills for admins and are writable over MCP, so no other schemes
  # and no embedded credentials.
  validate :url_is_plain_http
  enum link_type: {
    other: 0,
    proposal: 1,
    project_wiki: 2,
    design_file: 3,
    staging_link: 4,
    production_link: 5,
    qa_document: 6,
    operator_manual: 7,
    sow: 8,
    msa: 9,
    # Where the project's conversation lives, so Stacksbot can find the channel
    # and the homepage by id instead of by name-matching. Settable over MCP via
    # update_project_tracker (twist_channel_url / notion_homepage_url).
    twist_channel: 10,
    notion_homepage: 11,
  }

  private

  def url_is_plain_http
    parsed = begin
      URI.parse(url.to_s.strip)
    rescue URI::InvalidURIError
      nil
    end
    unless parsed.is_a?(URI::HTTP) && parsed.host.present?
      errors.add(:url, "must be an http or https URL")
      return
    end
    errors.add(:url, "must not embed credentials") if parsed.userinfo.present?
  end
end
