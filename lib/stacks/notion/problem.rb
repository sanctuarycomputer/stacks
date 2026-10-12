# Wraps a NotionPage row from Stacksbot's Problems database. See
# Stacks::Notion::Observation: same rules, nothing here raises.
class Stacks::Notion::Problem < Stacks::Notion::Base
  P = Stacks::Notion::Props

  SEVERITIES = %w[Critical High Medium Low].freeze # worst first
  CLOSED_STATUSES = %w[Resolved Dismissed].freeze
  UNOWNED_STATUS = "Open".freeze
  OWNED_STATUSES = %w[Owned Mitigating].freeze
  ESCALATING_SEVERITIES = %w[Critical High].freeze

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

  # Notion says nobody owns it yet. This is what the page prints.
  def unowned?
    status == UNOWNED_STATUS
  end

  # High or Critical and not known to be owned or closed. A blank or unknown
  # status escalates like Open does, for the same reason it counts as open.
  def escalating?
    open? && !OWNED_STATUSES.include?(status) && ESCALATING_SEVERITIES.include?(severity)
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
