class ProjectTrackerLink < ApplicationRecord
  belongs_to :project_tracker
  validates :name, presence: :true
  validates :url, format: URI::regexp(%w[http https])
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
end
