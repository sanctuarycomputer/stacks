# What the project log (/admin/project_trackers/:id/log) shows for one
# tracker and one view. It filters and orders rows the filtered Notion sync
# stored; every judgement in them (which project, valence, salience, what was
# folded into a Problem) was made by Stacksbot. Nothing here decides what an
# observation means, calls a model or writes anywhere.
#
# The filters are SQL over the stored jsonb and run before the LIMIT, so a
# page is never short while older rows still match. Each one has a Ruby twin
# on the wrappers (Stacks::Notion::Observation, Stacks::Notion::Problem) that
# the views print from; the tests hold the two together.
class Stacks::ProjectLog
  Observation = Stacks::Notion::Observation
  Problem = Stacks::Notion::Problem

  VIEWS = %w[attention highlights everything].freeze
  VIEW_LABELS = {
    "attention" => "Needs attention", "highlights" => "Highlights", "everything" => "Everything",
  }.freeze
  VALENCE_PARAMS = { "positive" => "Positive", "neutral" => "Neutral", "negative" => "Negative" }.freeze
  SOURCE_PARAMS = Observation::SOURCE_GROUP_LABELS.keys.freeze

  ATTENTION_WINDOW = 30.days
  ATTENTION_LIMIT = 500 # negative rows shown under Needs attention
  PROBLEM_LIMIT = 200   # open problems shown for a tracker
  PER_PAGE = 200        # rows per page of Highlights and Everything
  SUMMARY_ROWS = 3      # rows on the tracker page's module

  NEWEST_FIRST = "notion_pages.occurred_at DESC NULLS LAST, notion_pages.id DESC".freeze

  Row = Struct.new(:observation, :problems, :escalated, keyword_init: true)

  attr_reader :tracker, :view, :source, :valence, :page

  # Request parameters stop here: each is matched against a fixed list and
  # anything else falls back to its default. None is ever put into SQL.
  def initialize(tracker, view: nil, source: nil, valence: nil, page: nil, now: Time.zone.now)
    @tracker = tracker
    @now = now
    @view = VIEWS.include?(view) ? view : "attention"
    @source = SOURCE_PARAMS.include?(source) ? source : nil
    @valence = valence.is_a?(String) && VALENCE_PARAMS.key?(valence) ? valence : nil
    @page = page.is_a?(String) && page.match?(/\A[1-9]\d{0,2}\z/) && @view != "attention" ? page.to_i : 1
  end

  # A Negative observation that is High salience, or that was folded into a
  # Problem of severity High or Critical that nobody is known to own.
  # Derived, never stored. Its SQL twin is escalated_sql.
  def self.escalated?(observation, problems)
    observation.negative? && (observation.salience == "High" || problems.any?(&:escalating?))
  end

  # [css class, label, grey?]. A bare .pill has no background, so the two
  # grey ones are coloured by the view.
  def self.pill_for(row)
    return ["pill error", "Escalated", false] if row.escalated
    case row.observation.valence
    when "Negative" then ["pill at_risk", "Negative", false]
    when "Positive" then ["pill exceptional", "Positive", false]
    when "Neutral" then ["pill", "Neutral", true]
    else ["pill", "Not marked", true]
    end
  end

  # For the module on the tracker page: the counts of Needs attention, taken
  # by COUNT, and its first rows. Loads only the rows it shows.
  def self.summary(tracker, now: Time.zone.now)
    log = new(tracker, now: now)
    reason = log.empty_reason
    return { empty_reason: reason, open_problems: 0, negatives: 0, escalated: 0, latest: [] } if reason
    negatives, escalated = log.attention_counts
    { empty_reason: nil, open_problems: log.open_problem_count, negatives: negatives, escalated: escalated,
      latest: log.first_attention_rows(SUMMARY_ROWS) }
  end

  # Why the whole log is empty, most basic cause first; nil when the project
  # has any row at all (a view that shows none of them says so itself).
  def empty_reason
    return @empty_reason if defined?(@empty_reason)
    @empty_reason =
      if !tracker.notion_project_linked? then :no_notion_project
      elsif last_synced_at.nil? then :never_synced
      elsif !tracker.observations.exists? && !tracker.problems.exists? then :nothing_seen
      end
  end

  def last_synced_at
    return @last_synced_at if defined?(@last_synced_at)
    @last_synced_at = Stacks::Notion::FilteredSync.last_synced_at(:OBSERVATIONS)
  end

  # Open problems for the project, worst first, then most recently seen.
  def problems
    return [] unless view == "attention"
    @problems ||= open_problems
      .order(Arel.sql("#{severity_rank_sql} ASC, #{NEWEST_FIRST}"))
      .limit(PROBLEM_LIMIT).map(&:as_problem)
  end

  def open_problem_count
    open_problems.count
  end

  def rows
    @rows ||= build_rows(stored_rows.map(&:as_observation))
  end

  # [negative rows of the last 30 days, how many of them are escalated].
  def attention_counts
    attention_scope.pick(Arel.sql("COUNT(*)"), Arel.sql("COUNT(*) FILTER (WHERE #{escalated_sql})")).map(&:to_i)
  end

  # The first rows of Needs attention, whatever view this log is on.
  def first_attention_rows(count)
    build_rows(attention_scope.order(Arel.sql(attention_order_sql)).limit(count).map(&:as_observation))
  end

  # [[Monday, rows]], newest week first. Rows with no date are left out.
  def weeks
    rows.select { |r| r.observation.observed_at }
        .group_by { |r| r.observation.observed_at.to_date.beginning_of_week }
        .to_a
  end

  def older_page
    stored_rows
    @more && view != "attention" ? page + 1 : nil
  end

  def newer_page
    page > 1 ? page - 1 : nil
  end

  # Needs attention showed its limit and there were more.
  def capped?
    stored_rows
    @more && view == "attention"
  end

  def filtered?
    source.present? || valence.present?
  end

  # Some row shown takes its valence from its Type (Observation::INTERIM_VALENCE_BY_TYPE).
  def interim_in_use?
    rows.any? { |r| r.observation.valence_inferred? }
  end

  private

  # The stored rows this view shows, filtered and ordered by the database.
  # One query, reading one row past the limit to learn whether there are more.
  def stored_rows
    @stored_rows ||= begin
      limit = view == "attention" ? ATTENTION_LIMIT : PER_PAGE
      scope = view == "attention" ? attention_scope.order(Arel.sql(attention_order_sql)) : view_scope.order(Arel.sql(NEWEST_FIRST)).offset((page - 1) * limit)
      scope = with_chips(scope)
      found = scope.limit(limit + 1).to_a
      @more = found.size > limit
      found.first(limit)
    end
  end

  # Needs attention: Negative, not dismissed, in the last 30 days.
  def attention_scope
    gated(tracker.observations)
      .where("#{valence_sql} = ?", "Negative")
      .where("notion_pages.occurred_at >= ?", @now - ATTENTION_WINDOW)
  end

  def view_scope
    view == "highlights" ? gated(tracker.observations) : tracker.observations
  end

  # The gate: the row has a valence and is not dismissed. Stacks applies no
  # other test; what earns a valence is Stacksbot's call.
  def gated(scope)
    scope.where("#{valence_sql} IS NOT NULL")
         .where("#{select_sql('notion_pages', 'Status')} IS DISTINCT FROM ?", Observation::DISMISSED)
  end

  def with_chips(scope)
    scope = scope.where(source_group_sql(source)) if source
    scope = scope.where("#{valence_sql} = ?", VALENCE_PARAMS.fetch(valence)) if valence
    scope
  end

  def open_problems
    status = select_sql("notion_pages", "Status")
    tracker.problems.where("#{status} IS NULL OR #{status} NOT IN (#{quoted(Problem::CLOSED_STATUSES)})")
  end

  # Each observation with the problems it was folded into, from one query for
  # the whole list. A link counts whichever side holds it: the observation's
  # Problems relation or the problem's Source Observations.
  def build_rows(list)
    return [] if list.empty?
    named = list.flat_map(&:problem_ids).uniq
    linked_from = list.map { |o| [{ "id" => o.notion_id }].to_json }
    known = NotionPage.problems
      .where("notion_pages.notion_id IN (?) OR (#{relation_sql('notion_pages', 'Source Observations')}) @> ANY (ARRAY[?]::jsonb[])",
             named, linked_from)
      .map(&:as_problem)
    by_id = known.index_by(&:notion_id)
    by_observation = {}
    known.each { |p| p.source_observation_ids.each { |oid| (by_observation[oid] ||= []) << p } }

    list.map do |o|
      problems = (o.problem_ids.filter_map { |id| by_id[id] } + by_observation.fetch(o.notion_id, [])).uniq(&:notion_id)
      Row.new(observation: o, problems: problems, escalated: self.class.escalated?(o, problems))
    end
  end

  # --- SQL over notion_pages.data ------------------------------------------
  # Every name and value below is a constant from this code, quoted by the
  # connection. No request parameter is ever part of these strings.

  def quoted(values)
    Array(values).map { |v| ActiveRecord::Base.connection.quote(v) }.join(", ")
  end

  # A select property's option name, as Stacks::Notion::Props.select reads
  # it: trimmed, NULL when blank, and from the "status" key when Notion holds
  # the property as a status.
  def select_sql(table, property)
    path = ->(type) { "#{table}.data #>> ARRAY['properties', #{quoted(property)}, '#{type}', 'name']" }
    "NULLIF(btrim(COALESCE(#{path.('select')}, #{path.('status')})), '')"
  end

  def relation_sql(table, property)
    "#{table}.data #> ARRAY['properties', #{quoted(property)}, 'relation']"
  end

  # Observation#valence: the stored valence when it is a known one, else what
  # the interim rule gives its Type (Observation::INTERIM_VALENCE_BY_TYPE).
  def valence_sql
    stored = select_sql("notion_pages", Observation::VALENCE_PROPERTY)
    type = select_sql("notion_pages", "Type")
    interim = Observation::INTERIM_VALENCE_BY_TYPE.map { |t, v| "WHEN #{type} = #{quoted(t)} THEN #{quoted(v)}" }.join(" ")
    "(CASE WHEN #{stored} IN (#{quoted(Observation::VALENCES)}) THEN #{stored} #{interim} END)"
  end

  # Observation#source_group, for one whitelisted chip.
  def source_group_sql(group)
    name = "lower(#{select_sql('notion_pages', 'Source')})"
    named = ->(g) { "#{name} IN (#{quoted(Observation::SOURCE_GROUPS.fetch(g))})" }
    case group
    when "notion" then "#{name} LIKE 'notion%'"
    when "other"
      known = Observation::SOURCE_GROUPS.keys.map { |g| named.(g) }.join(" OR ")
      "(#{name} IS NULL OR NOT (#{known} OR #{name} LIKE 'notion%'))"
    else named.(group)
    end
  end

  # Problem#severity_rank.
  def severity_rank_sql
    severity = select_sql("notion_pages", "Severity")
    cases = Problem::SEVERITIES.each_with_index.map { |s, i| "WHEN #{quoted(s)} THEN #{i}" }.join(" ")
    "(CASE #{severity} #{cases} ELSE #{Problem::SEVERITIES.size} END)"
  end

  # self.escalated? for a row already known to be Negative: High salience, or
  # linked from either side to a Problem that is Problem#escalating?.
  def escalated_sql
    severity = select_sql("log_problems", "Severity")
    status = select_sql("log_problems", "Status")
    <<~SQL.squish
      (#{select_sql('notion_pages', 'Salience')} = 'High' OR EXISTS (
        SELECT 1 FROM notion_pages log_problems
        WHERE log_problems.deleted_at IS NULL
          AND log_problems.notion_parent_type = 'database_id'
          AND log_problems.notion_parent_id = #{quoted(Stacks::Notion.filtered_parent_id(:PROBLEMS))}
          AND #{severity} IN (#{quoted(Problem::ESCALATING_SEVERITIES)})
          AND (#{status} IS NULL OR #{status} NOT IN (#{quoted(Problem::OWNED_STATUSES + Problem::CLOSED_STATUSES)}))
          AND ((#{relation_sql('notion_pages', 'Problems')}) @> jsonb_build_array(jsonb_build_object('id', log_problems.notion_id))
               OR (#{relation_sql('log_problems', 'Source Observations')}) @> jsonb_build_array(jsonb_build_object('id', notion_pages.notion_id)))
      ))
    SQL
  end

  # Needs attention's order: escalated first, then newest first.
  def attention_order_sql
    "(CASE WHEN #{escalated_sql} THEN 0 ELSE 1 END) ASC, #{NEWEST_FIRST}"
  end
end
