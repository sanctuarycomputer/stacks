# Wraps a NotionPage row from Stacksbot's Problems database. See
# Stacks::Notion::Observation: same rules, nothing here raises.
class Stacks::Notion::Problem < Stacks::Notion::Base
  include Stacks::Notion::Flag # flag?, flag_inferred?, flag_reason
  P = Stacks::Notion::Props

  SEVERITIES = %w[Critical High Medium Low].freeze # worst first
  CLOSED_STATUSES = %w[Resolved Dismissed].freeze
  UNOWNED_STATUS = "Open".freeze
  OWNED_STATUSES = %w[Owned Mitigating].freeze
  # INTERIM, for pages synced before Notion had a Flag property: a page with
  # no Flag in its stored data is flagged by interim_flag? below. A Flag that
  # Notion states always wins (Stacks::Notion::Flag). Once every stored page
  # carries Flag, delete this constant and interim_flag?, and have flag? read
  # the property alone.
  INTERIM_FLAG_SEVERITIES = %w[Critical High].freeze

  def self.project_ids_in(data)
    P.relation_ids(data, "Project")
  end

  def self.occurred_at_in(data)
    P.time(data, "Last Seen") || P.time(data, "First Seen") || P.parse_time(P.top(data, "created_time"))
  end

  def title
    P.text(notion_page.data, "Problem", "title").presence || notion_page.page_title.presence || "Untitled"
  end

  def kind
    P.select(notion_page.data, "Kind")
  end

  def severity
    value = P.select(notion_page.data, "Severity")
    SEVERITIES.include?(value) ? value : nil
  end

  def severity_rank
    SEVERITIES.index(severity) || SEVERITIES.size
  end

  def status
    P.select(notion_page.data, "Status")
  end

  # A blank or unknown status counts as open: better shown than hidden.
  def open?
    !CLOSED_STATUSES.include?(status)
  end

  # Notion's status says it has not been picked up yet.
  def unowned?
    status == UNOWNED_STATUS
  end

  # INTERIM (see INTERIM_FLAG_SEVERITIES): open, High or Critical, and not
  # known to be owned. A blank or unknown status flags like Open does, for
  # the same reason it counts as open.
  def interim_flag?
    open? && !OWNED_STATUSES.include?(status) && INTERIM_FLAG_SEVERITIES.include?(severity)
  end

  def owner_names
    names = P.people_names(notion_page.data, "Owner")
    names.any? ? names : [P.text(notion_page.data, "Owner Name").presence].compact
  end

  def occurrences
    value = P.number(notion_page.data, "Occurrences")
    value&.to_i
  end

  def last_seen_at
    P.time(notion_page.data, "Last Seen")
  end

  def first_seen_at
    P.time(notion_page.data, "First Seen")
  end

  # When it last came up: Last Seen, else First Seen, else the date the sync
  # stored on the row. nil when Notion gives none of them.
  def seen_at
    last_seen_at || first_seen_at || notion_page.occurred_at
  end

  # What Stacksbot suggests doing about it, as plain text. "" when blank.
  def proposed_action
    P.text(notion_page.data, "Proposed Action")
  end

  def project_ids
    self.class.project_ids_in(notion_page.data)
  end

  def source_observation_ids
    P.relation_ids(notion_page.data, "Source Observations")
  end

  def notion_url
    P.http_url(P.top(notion_page.data, "url")) || notion_page.notion_link
  end
end
