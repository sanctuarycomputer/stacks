# Wraps a NotionPage row from Stacksbot's Observations database. Every field
# was written by Stacksbot or edited by a person, so every reader goes through
# Stacks::Notion::Props and none of them raises.
class Stacks::Notion::Observation < Stacks::Notion::Base
  include Stacks::Notion::Flag # flag?, flag_inferred?, flag_reason
  P = Stacks::Notion::Props

  VALENCE_PROPERTY = "Valence".freeze
  VALENCES = %w[Positive Neutral Negative].freeze
  SALIENCES = %w[High Medium Low].freeze
  DISMISSED = "Dismissed".freeze

  # INTERIM, until Stacksbot writes Valence (spec Part 3): a row with no
  # valence shows the valence its Type implies. A stored valence always wins.
  # To remove the rule, replace this value with {}.freeze.
  INTERIM_VALENCE_BY_TYPE = { "Risk" => "Negative", "Win" => "Positive" }.freeze

  # INTERIM, for pages synced before Notion had a Flag property: a page with
  # no Flag in its stored data is flagged by interim_flag? below. A Flag that
  # Notion states always wins (Stacks::Notion::Flag). Once every stored page
  # carries Flag, delete this constant and interim_flag?, and have flag? read
  # the property alone.
  INTERIM_FLAG_SALIENCE = "High".freeze

  # How the Source select groups for the log's chips. Display only.
  SOURCE_GROUPS = {
    "twist" => ["twist"],
    "meet" => ["meet", "google meet", "gemini notes"],
    "mail" => ["google groups", "google_groups", "gmail"],
  }.freeze
  SOURCE_GROUP_LABELS = {
    "twist" => "Twist", "meet" => "Meet", "mail" => "Mail", "notion" => "Notion", "other" => "Other",
  }.freeze

  def self.project_ids_in(data)
    P.relation_ids(data, "Projects")
  end

  def self.problem_ids_in(data)
    P.relation_ids(data, "Problems")
  end

  # The date a row sorts by: when it was observed, else when it was created.
  def self.occurred_at_in(data)
    P.time(data, "Observed At") || P.parse_time(P.top(data, "created_time"))
  end

  def title
    P.text(notion_page.data, "Name", "title").presence || notion_page.page_title.presence || "Untitled"
  end

  def text
    P.text(notion_page.data, "Observation")
  end

  def source
    P.select(notion_page.data, "Source")
  end

  def source_group
    name = source.to_s.downcase
    return "notion" if name.start_with?("notion")
    SOURCE_GROUPS.each { |group, names| return group if names.include?(name) }
    "other"
  end

  def source_url
    P.url(notion_page.data, "Source Ref")
  end

  def notion_url
    P.http_url(P.top(notion_page.data, "url")) || notion_page.notion_link
  end

  def observed_at
    notion_page.occurred_at || self.class.occurred_at_in(notion_page.data)
  end

  def salience
    value = P.select(notion_page.data, "Salience")
    SALIENCES.include?(value) ? value : nil
  end

  def type
    P.select(notion_page.data, "Type")
  end

  def status
    P.select(notion_page.data, "Status")
  end

  def dismissed?
    status == DISMISSED
  end

  def stored_valence
    value = P.select(notion_page.data, VALENCE_PROPERTY)
    VALENCES.include?(value) ? value : nil
  end

  def valence
    stored_valence || INTERIM_VALENCE_BY_TYPE[type]
  end

  def valence_inferred?
    stored_valence.nil? && valence.present?
  end

  def negative?
    valence == "Negative"
  end

  # INTERIM (see INTERIM_FLAG_SALIENCE): Negative, High salience, not dismissed.
  def interim_flag?
    negative? && salience == INTERIM_FLAG_SALIENCE && !dismissed?
  end

  def project_ids
    self.class.project_ids_in(notion_page.data)
  end

  def problem_ids
    self.class.problem_ids_in(notion_page.data)
  end
end
