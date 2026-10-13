# What the project log (/admin/project_trackers/:id/log) shows for one
# tracker: its flags, its other open problems, its wins and every observation.
# It filters and orders rows the filtered Notion sync stored; every judgement
# in them (which project, valence, salience, severity, who owns what, what was
# folded into a Problem) was made by Stacksbot or by a person in Notion.
# Nothing here decides what an observation means, calls a model or writes
# anywhere.
#
# WHAT IS A FLAG, AND WHY, is Notion's call, not Stacks': the Flag formula on
# a Problem or an Observation gives the reason as text when the page is a flag
# and nothing when it is not (Stacks::Notion::Flag: flag?, flag_reason). What
# Notion states wins outright. Only a page synced before the property existed
# falls back to the interim rule on its wrapper (interim_flag?).
#
# WHAT STACKS ADDS is view logic only, applied in one place (flags_for):
#
#   1. A problem flag: a Problem filed under one of the tracker's Notion
#      projects whose flag? is true, that is not Resolved or Dismissed (a
#      stale Flag on a closed problem shows nothing), and that was last seen
#      (Problem#seen_at) within FLAG_WINDOW. A problem with no date at all
#      still counts.
#   2. An observation flag: an observation filed under one of the tracker's
#      Notion projects whose flag? is true, that is not Dismissed, dated
#      within FLAG_WINDOW, and not tied to a problem flag of (1). A tie counts
#      whichever side holds it: the observation's Problems relation or the
#      problem's Source Observations. A tied observation is that flag's
#      evidence instead, so nothing is counted twice.
#
# Nothing in Stacks clears a flag. It goes when Notion changes and the next
# sync lands: Notion stops flagging it, the problem is Resolved or Dismissed,
# the observation is Dismissed or folded into a problem flag, or it has not
# come up for FLAG_WINDOW. Under the interim rule "Notion stops flagging it"
# means someone takes the problem (Owned or Mitigating).
#
# The log page, the tracker page's module and the trackers index all count
# from flags_for, so their numbers cannot differ.
class Stacks::ProjectLog
  Observation = Stacks::Notion::Observation
  Problem = Stacks::Notion::Problem

  VALENCE_PARAMS = { "positive" => "Positive", "neutral" => "Neutral", "negative" => "Negative" }.freeze
  SOURCE_PARAMS = Observation::SOURCE_GROUP_LABELS.keys.freeze

  FLAG_WINDOW = 30.days # how recent a flag, and a win, has to be
  PROBLEM_LIMIT = 200   # open problems read for a tracker
  EVIDENCE_LIMIT = 5    # observations listed under one problem flag
  EVIDENCE_READ = 500   # observations read as evidence for a whole page
  WINS_LIMIT = 20       # wins listed; the header carries the full count
  PER_PAGE = 200        # rows per page of All Observations
  SUMMARY_FLAGS = 3     # flags on the tracker page's module

  NEWEST_FIRST = "notion_pages.occurred_at DESC NULLS LAST, notion_pages.id DESC".freeze
  DATE_FORMAT = "%b %-d, %Y".freeze

  STATED_WITHOUT_REASON = "Flagged in Notion.".freeze
  PROBLEM_NEXT_STEP = "Pick it up or resolve it in Notion.".freeze
  OBSERVATION_NEXT_STEP = "Read the source. If it is a real problem, raise it; otherwise dismiss it in Notion.".freeze

  # One row of All Observations or Wins. flag: it is a flag, or evidence of one.
  Row = Struct.new(:observation, :problems, :flag, keyword_init: true)

  # One flag: a Problem (kind :problem, with the observations tied to it as
  # evidence) or an Observation (kind :observation). Everything it prints is
  # either a fixed phrase or text from Notion, which the view escapes.
  Flag = Struct.new(:kind, :problem, :observation, :evidence, :evidence_more, keyword_init: true) do
    def record
      problem || observation
    end

    def notion_id
      record.notion_id
    end

    def title
      record.title
    end

    def notion_url
      record.notion_url
    end

    def seen_at
      problem ? problem.seen_at : observation.observed_at
    end

    # Why it is a flag: Notion's sentence, then the facts Stacks holds about
    # when it came up.
    def why
      reason = self.reason
      reason = "#{reason}." unless reason.match?(/[.!?]\z/)
      [reason, sighting].compact.join(" ")
    end

    # Notion's reason when its Flag gives one. A Flag that is only a yes has
    # none, so a fixed line; a page with no Flag gets the interim rule's words.
    def reason
      record.flag_reason || (record.flag_inferred? ? interim_reason : STATED_WITHOUT_REASON)
    end

    def sighting
      seen = seen_at&.strftime(DATE_FORMAT)
      if problem
        times = problem.occurrences.to_i
        if times > 1 then seen ? "Seen #{times} times, last on #{seen}." : "Seen #{times} times."
        elsif seen then "Last seen on #{seen}."
        end
      elsif observation.source || seen
        ["Seen", observation.source && "in #{observation.source}", seen && "on #{seen}"].compact.join(" ") + "."
      end
    end

    # INTERIM: goes with interim_flag? on the wrappers.
    def interim_reason
      if problem then "#{problem.severity} severity problem. #{Stacks::ProjectLog.ownership_words(problem)}."
      else "High-salience negative observation."
      end
    end

    # Stacksbot's Proposed Action when the problem has one, else a fixed line.
    def next_step
      return OBSERVATION_NEXT_STEP unless problem
      problem.proposed_action.presence || PROBLEM_NEXT_STEP
    end

  end

  attr_reader :tracker, :source, :valence, :page

  # Request parameters stop here: each is matched against a fixed list and
  # anything else falls back to its default. None is ever put into SQL. They
  # apply to All Observations only.
  def initialize(tracker, source: nil, valence: nil, page: nil, now: Time.zone.now)
    @tracker = tracker
    @now = now
    @source = SOURCE_PARAMS.include?(source) ? source : nil
    @valence = valence.is_a?(String) && VALENCE_PARAMS.key?(valence) ? valence : nil
    @page = page.is_a?(String) && page.match?(/\A[1-9]\d{0,2}\z/) ? page.to_i : 1
  end

  # { tracker id => number of flags }, for the trackers index. Only trackers
  # with a flag are in it. Four queries however many trackers there are. A
  # tracker whose log page would show an empty state (nothing synced yet, no
  # Notion project) has no flags here either.
  def self.flag_counts(trackers, now: Time.zone.now)
    list = Array(trackers).compact
    return {} if list.empty? || Stacks::Notion::FilteredSync.last_synced_at(:OBSERVATIONS).nil?
    chosen = list.flat_map { |t| project_ids_of(t) }.uniq
    return {} if chosen.empty?
    live = NotionPage.projects.where(notion_id: chosen).pluck(:notion_id).to_set
    linked = list.select { |t| project_ids_of(t).any? { |id| live.include?(id) } }
    flags_for(linked, now: now).transform_values(&:size).reject { |_, count| count.zero? }
  end

  # The flags of any number of trackers: { tracker id => [Flag] }, the problem
  # flags worst severity first then most recently seen, then the observation
  # flags newest first. Two queries. Evidence is not read here.
  #
  # The SQL narrows what is read with the same test, in the same order of
  # precedence, as the wrappers' flag? (flag_sql); the wrappers then decide.
  def self.flags_for(trackers, now:)
    ids_by_tracker = trackers.to_h { |t| [t.id, project_ids_of(t)] }
    all_ids = ids_by_tracker.values.flatten.uniq
    return ids_by_tracker.transform_values { [] } if all_ids.empty?

    filed = ->(scope) { scope.where("notion_pages.project_ids && ARRAY[?]::varchar[]", all_ids) }
    problems = filed.(NotionPage.problems).where(problem_flag_sql).map(&:as_problem)
                    .select { |p| problem_flag?(p, now) }
                    .sort_by { |p| [p.severity_rank, -(p.seen_at || now).to_f, p.notion_id] }
    observations = filed.(NotionPage.observations).where(observation_flag_sql, now - FLAG_WINDOW)
                        .order(Arel.sql(NEWEST_FIRST)).map(&:as_observation)
                        .select { |o| observation_flag?(o, now) }

    ids_by_tracker.transform_values do |ids|
      mine = problems.select { |p| (p.project_ids & ids).any? }
      problem_ids = mine.map(&:notion_id)
      sources = mine.flat_map(&:source_observation_ids).to_set
      alone = observations.select do |o|
        (o.project_ids & ids).any? && (o.problem_ids & problem_ids).empty? && !sources.include?(o.notion_id)
      end
      mine.map { |p| Flag.new(kind: :problem, problem: p, evidence: [], evidence_more: 0) } +
        alone.map { |o| Flag.new(kind: :observation, observation: o, evidence: [], evidence_more: 0) }
    end
  end

  # Rule (1) for one stored problem: Notion flags it (or the interim rule
  # does), it is not closed, and it has come up within the window.
  def self.problem_flag?(problem, now)
    problem.flag? && problem.open? && (problem.seen_at.nil? || problem.seen_at >= now - FLAG_WINDOW)
  end

  # Rule (2) without the tie test, for one stored observation.
  def self.observation_flag?(observation, now)
    observation.flag? && !observation.dismissed? &&
      observation.observed_at.present? && observation.observed_at >= now - FLAG_WINDOW
  end

  def self.project_ids_of(tracker)
    Array(tracker.notion_project_ids).select(&:present?)
  end

  # "Nobody owns it yet", "Owned by X", "Being mitigated by X": a problem's
  # Notion status and owner, in words.
  def self.ownership_words(problem)
    names = problem.owner_names.to_sentence.presence
    case problem.status
    when Problem::UNOWNED_STATUS then "Nobody owns it yet"
    when "Owned" then names ? "Owned by #{names}" : "Owned, with no owner named in Notion"
    when "Mitigating" then names ? "Being mitigated by #{names}" : "Being mitigated, with no owner named in Notion"
    when nil then "No status in Notion"
    else "Status in Notion: #{problem.status}"
    end
  end

  # [css class, label, grey?] for a row's valence. A bare .pill has no
  # background, so the two grey ones are coloured by the view.
  def self.pill_for(row)
    case row.observation.valence
    when "Negative" then ["pill at_risk", "Negative", false]
    when "Positive" then ["pill exceptional", "Positive", false]
    when "Neutral" then ["pill", "Neutral", true]
    else ["pill", "Not marked", true]
    end
  end

  # For the module on the tracker page: the flag count, the wins of the last
  # 30 days (by COUNT) and the first flags. Reads no evidence and no rows.
  def self.summary(tracker, now: Time.zone.now)
    log = new(tracker, now: now)
    reason = log.empty_reason
    return { empty_reason: reason, flags: 0, wins: 0, latest: [] } if reason
    { empty_reason: nil, flags: log.flag_count, wins: log.win_count, latest: log.bare_flags.first(SUMMARY_FLAGS) }
  end

  # Reads everything the log page prints, so a read that fails does so here,
  # before any of the page is drawn. Returns self.
  def load!
    return self if empty_reason
    flags
    other_problems
    wins
    win_count
    rows
    older_page
    self
  end

  # Why the whole log is empty, most basic cause first; nil when the project
  # has any row at all (a section that shows none of them says so itself).
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

  # The flags, each problem flag with the observations tied to it.
  def flags
    @flags ||= with_evidence(bare_flags)
  end

  # The flags without their evidence: all a count or the module needs.
  def bare_flags
    @bare_flags ||= empty_reason ? [] : self.class.flags_for([tracker], now: @now).fetch(tracker.id, [])
  end

  def flag_count
    bare_flags.size
  end

  # Open problems that are not flags: lower severity, already taken, or not
  # seen for a while. Worst first, then most recently seen.
  def other_problems
    @other_problems ||=
      if empty_reason then []
      else
        flagged = problem_flag_ids
        open_problems.order(Arel.sql("#{severity_rank_sql} ASC, #{NEWEST_FIRST}")).limit(PROBLEM_LIMIT)
                     .map(&:as_problem).reject { |p| flagged.include?(p.notion_id) }
      end
  end

  # Why an open problem is not a flag, when the reason is one Stacks can
  # state: Notion flags it but it has gone quiet, or (under the interim rule
  # only) it would be flagged were it not already taken. nil otherwise: a
  # lower severity, or Notion's own Flag saying no.
  def not_a_flag_reason(problem)
    return nil unless problem.open?
    return "Not a flag: not seen for #{FLAG_WINDOW.in_days.to_i} days." if problem.flag?
    return nil unless problem.flag_inferred? && Problem::INTERIM_FLAG_SEVERITIES.include?(problem.severity)
    names = problem.owner_names.to_sentence.presence
    many = problem.owner_names.size > 1
    case problem.status
    when "Owned" then names ? "Not a flag: #{names} #{many ? 'own' : 'owns'} it." : "Not a flag: it is owned."
    when "Mitigating" then names ? "Not a flag: #{names} #{many ? 'are' : 'is'} mitigating it." : "Not a flag: it is being mitigated."
    end
  end

  # Some problem or observation on the page has no Flag in Notion, so whether
  # it is a flag came from the interim rule (interim_flag? on the wrappers).
  def interim_flag_in_use?
    shown = bare_flags.map(&:record) + other_problems + rows.map(&:observation) + wins.map(&:observation)
    shown.any?(&:flag_inferred?)
  end

  # Positive observations of the last 30 days, newest first, at most WINS_LIMIT.
  def wins
    @wins ||= empty_reason ? [] : build_rows(wins_scope.order(Arel.sql(NEWEST_FIRST)).limit(WINS_LIMIT).map(&:as_observation))
  end

  def win_count
    @win_count ||= empty_reason ? 0 : wins_scope.count
  end

  def more_wins?
    win_count > wins.size
  end

  # All Observations: one page of every row filed under the project.
  def rows
    @rows ||= build_rows(stored_rows.map(&:as_observation))
  end

  def older_page
    stored_rows
    @more ? page + 1 : nil
  end

  def newer_page
    page > 1 ? page - 1 : nil
  end

  def filtered?
    source.present? || valence.present?
  end

  # Some row shown takes its valence from its Type (Observation::INTERIM_VALENCE_BY_TYPE).
  def interim_in_use?
    shown = rows.map(&:observation) + wins.map(&:observation) + bare_flags.filter_map(&:observation)
    shown.any?(&:valence_inferred?)
  end

  private

  # One page of All Observations, filtered and ordered by the database. One
  # query, reading one row past the limit to learn whether there are more.
  def stored_rows
    @stored_rows ||=
      if empty_reason
        @more = false
        []
      else
        scope = filtered(tracker.observations).order(Arel.sql(NEWEST_FIRST)).offset((page - 1) * PER_PAGE)
        found = scope.limit(PER_PAGE + 1).to_a
        @more = found.size > PER_PAGE
        found.first(PER_PAGE)
      end
  end

  def filtered(scope)
    scope = scope.where(self.class.source_group_sql(source)) if source
    scope = scope.where("#{self.class.valence_sql} = ?", VALENCE_PARAMS.fetch(valence)) if valence
    scope
  end

  def wins_scope
    tracker.observations
           .where("#{self.class.valence_sql} = ?", "Positive")
           .where(self.class.not_dismissed_sql)
           .where("notion_pages.occurred_at >= ?", @now - FLAG_WINDOW)
  end

  def open_problems
    status = self.class.select_sql("notion_pages", "Status")
    tracker.problems.where("#{status} IS NULL OR #{status} NOT IN (#{self.class.quoted(Problem::CLOSED_STATUSES)})")
  end

  def problem_flags
    bare_flags.select(&:problem)
  end

  def problem_flag_ids
    @problem_flag_ids ||= problem_flags.map(&:notion_id).to_set
  end

  # Ids of the observations that are flags, or that a problem flag names.
  def flagged_observation_ids
    @flagged_observation_ids ||=
      (bare_flags.filter_map(&:observation).map(&:notion_id) + problem_flags.flat_map { |f| f.problem.source_observation_ids }).to_set
  end

  # A row of All Observations is part of a flag when it is one, or is tied to
  # a problem flag from either side. A Dismissed row never is.
  def part_of_a_flag?(observation)
    return false if observation.dismissed?
    flagged_observation_ids.include?(observation.notion_id) || observation.problem_ids.any? { |id| problem_flag_ids.include?(id) }
  end

  # Each problem flag with the observations tied to it from either side: this
  # tracker's rows only, never a Dismissed one. One query for the whole page.
  # The ones that would have been flags themselves come first, then newest.
  def with_evidence(list)
    problems = list.filter_map(&:problem)
    return list if problems.empty?
    named = problems.flat_map(&:source_observation_ids).uniq
    links = problems.map { |p| [{ "id" => p.notion_id }].to_json }
    found = tracker.observations.where(self.class.not_dismissed_sql)
      .where("notion_pages.notion_id IN (?) OR (#{self.class.relation_sql('notion_pages', 'Problems')}) @> ANY (ARRAY[?]::jsonb[])",
             named.presence || [""], links)
      .order(Arel.sql(NEWEST_FIRST)).limit(EVIDENCE_READ).map(&:as_observation)

    list.map do |flag|
      next flag unless flag.problem
      sources = flag.problem.source_observation_ids
      tied = found.select { |o| o.problem_ids.include?(flag.notion_id) || sources.include?(o.notion_id) }
      tied = tied.partition { |o| self.class.observation_flag?(o, @now) }.flatten
      Flag.new(kind: :problem, problem: flag.problem, evidence: tied.first(EVIDENCE_LIMIT),
               evidence_more: [tied.size - EVIDENCE_LIMIT, 0].max)
    end
  end

  # Each observation with the problems it was folded into, from one query for
  # the whole list. A link counts whichever side holds it: the observation's
  # Problems relation or the problem's Source Observations.
  def build_rows(list)
    return [] if list.empty?
    named = list.flat_map(&:problem_ids).uniq
    linked_from = list.map { |o| [{ "id" => o.notion_id }].to_json }
    known = NotionPage.problems
      .where("notion_pages.notion_id IN (?) OR (#{self.class.relation_sql('notion_pages', 'Source Observations')}) @> ANY (ARRAY[?]::jsonb[])",
             named.presence || [""], linked_from)
      .map(&:as_problem)
    by_id = known.index_by(&:notion_id)
    by_observation = {}
    known.each { |p| p.source_observation_ids.each { |oid| (by_observation[oid] ||= []) << p } }

    list.map do |o|
      problems = (o.problem_ids.filter_map { |id| by_id[id] } + by_observation.fetch(o.notion_id, [])).uniq(&:notion_id)
      Row.new(observation: o, problems: problems, flag: part_of_a_flag?(o))
    end
  end

  # Problem#severity_rank.
  def severity_rank_sql
    severity = self.class.select_sql("notion_pages", "Severity")
    cases = Problem::SEVERITIES.each_with_index.map { |s, i| "WHEN #{self.class.quoted(s)} THEN #{i}" }.join(" ")
    "(CASE #{severity} #{cases} ELSE #{Problem::SEVERITIES.size} END)"
  end

  # --- SQL over notion_pages.data ------------------------------------------
  # Every name and value below is a constant from this code, quoted by the
  # connection. No request parameter is ever part of these strings.
  class << self
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

    # !Observation#dismissed?
    def not_dismissed_sql
      "#{select_sql('notion_pages', 'Status')} IS DISTINCT FROM #{quoted(Observation::DISMISSED)}"
    end

    # Stacks::Notion::Props.flagged for the Flag property: SQL true or false
    # when Notion states it, SQL NULL when the page has no such property or it
    # is of another shape. In Props' order: a text formula (flagged when it
    # gives any text), then a checkbox, then a boolean formula (an empty
    # result reading as false).
    def stated_flag_sql
      at = ->(*keys) { "notion_pages.data #> ARRAY['properties', #{quoted(Stacks::Notion::Flag::PROPERTY)}, #{quoted(keys)}]" }
      text = "notion_pages.data #>> ARRAY['properties', #{quoted(Stacks::Notion::Flag::PROPERTY)}, 'formula', 'string']"
      <<~SQL.squish
        (CASE
          WHEN jsonb_typeof(#{at.('formula')}) = 'object' AND #{at.('formula', 'type')} = '"string"'::jsonb
            THEN COALESCE(jsonb_typeof(#{at.('formula', 'string')}) = 'string' AND #{text} ~ '[^[:space:]]', FALSE)
          WHEN jsonb_typeof(#{at.('checkbox')}) = 'boolean' THEN #{at.('checkbox')} = 'true'::jsonb
          WHEN jsonb_typeof(#{at.('formula')}) = 'object' AND #{at.('formula', 'type')} = '"boolean"'::jsonb
            THEN COALESCE(#{at.('formula', 'boolean')} = 'true'::jsonb, FALSE)
        END)
      SQL
    end

    # Problem#flag? (:problem) or Observation#flag? (:observation): what
    # Notion's Flag states when the page has one, else the interim rule.
    def flag_sql(kind)
      interim = kind == :problem ? interim_problem_flag_sql : interim_observation_flag_sql
      "COALESCE(#{stated_flag_sql}, #{interim}, FALSE)"
    end

    # Rule (1) without the window: flagged and not closed.
    def problem_flag_sql
      status = select_sql("notion_pages", "Status")
      "#{flag_sql(:problem)} AND (#{status} IS NULL OR #{status} NOT IN (#{quoted(Problem::CLOSED_STATUSES)}))"
    end

    # Rule (2) without the tie test: flagged, not Dismissed, and dated on or
    # after the one bound value (the start of the window).
    def observation_flag_sql
      "#{flag_sql(:observation)} AND #{not_dismissed_sql} AND notion_pages.occurred_at >= ?"
    end

    # INTERIM. Problem#interim_flag?
    def interim_problem_flag_sql
      severity = select_sql("notion_pages", "Severity")
      status = select_sql("notion_pages", "Status")
      "(#{severity} IN (#{quoted(Problem::INTERIM_FLAG_SEVERITIES)}) " \
        "AND (#{status} IS NULL OR #{status} NOT IN (#{quoted(Problem::OWNED_STATUSES + Problem::CLOSED_STATUSES)})))"
    end

    # INTERIM. Observation#interim_flag?
    def interim_observation_flag_sql
      "(#{valence_sql} = 'Negative' AND #{select_sql('notion_pages', 'Salience')} = #{quoted(Observation::INTERIM_FLAG_SALIENCE)} " \
        "AND #{not_dismissed_sql})"
    end

    # Observation#source_group, for one whitelisted filter value.
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
  end
end
