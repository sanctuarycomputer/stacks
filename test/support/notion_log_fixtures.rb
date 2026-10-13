# Builders for Stacksbot's Observations and Problems rows as Notion sends
# them, and a stand-in Notion client, so no test of the project log reaches
# the network.
module NotionLogFixtures
  def nl_select(name)
    { "type" => "select", "select" => name && { "name" => name } }
  end

  def nl_relation(ids, has_more: false)
    { "type" => "relation", "relation" => ids.map { |id| { "id" => id } }, "has_more" => has_more }
  end

  def nl_text(type, value)
    { "type" => type, type => value.nil? ? [] : [{ "type" => "text", "plain_text" => value }] }
  end

  # Notion's Flag. A String (or shape :text) is what Notion holds today: a
  # formula giving the reason as text, empty when the page is no flag. true
  # and false make a checkbox, or a boolean formula with shape :formula.
  def nl_flag(value, shape = :checkbox)
    return { "type" => "formula", "formula" => { "type" => "string", "string" => value } } if value.is_a?(String) || shape == :text
    return { "type" => "checkbox", "checkbox" => value } if shape == :checkbox
    { "type" => "formula", "formula" => { "type" => "boolean", "boolean" => value } }
  end

  def nl_date(time)
    { "type" => "date", "date" => time && { "start" => time.iso8601 } }
  end

  # valence: nil with valence_property: false is today's Notion (no such
  # property); valence: nil with valence_property: true is an empty select.
  def observation_data(id: SecureRandom.uuid, name: "Observation", text: "Seen.", source: "Twist",
                       source_ref: "https://twist.com/a/133876/ch/1/t/2/", observed_at: Time.zone.now,
                       salience: "Medium", type: "FYI", status: "New", valence: nil, valence_property: true,
                       flag: :absent, flag_shape: :checkbox,
                       project_ids: [], problem_ids: [], edited: Time.zone.now, archived: false)
    props = {
      "Name" => nl_text("title", name), "Observation" => nl_text("rich_text", text),
      "Source" => nl_select(source), "Source Ref" => { "type" => "url", "url" => source_ref },
      "Observed At" => nl_date(observed_at), "Salience" => nl_select(salience), "Type" => nl_select(type),
      "Status" => nl_select(status), "Projects" => nl_relation(project_ids), "Problems" => nl_relation(problem_ids),
    }
    props["Valence"] = nl_select(valence) if valence_property || valence
    props["Flag"] = nl_flag(flag, flag_shape) unless flag == :absent
    { "object" => "page", "id" => id, "url" => "https://www.notion.so/#{id.delete('-')}",
      "created_time" => (observed_at || edited).utc.iso8601, "last_edited_time" => edited.utc.iso8601,
      "archived" => archived,
      "parent" => { "type" => "database_id", "database_id" => Stacks::Notion.filtered_parent_id(:OBSERVATIONS) },
      "properties" => props }
  end

  def problem_data(id: SecureRandom.uuid, name: "Problem", kind: "delivery", severity: "High", status: "Open",
                   owner: nil, occurrences: 1, last_seen: Time.zone.now, first_seen: nil, proposed_action: nil,
                   flag: :absent, flag_shape: :checkbox, not_a_flag_because: :absent,
                   project_ids: [], source_observation_ids: [], edited: Time.zone.now, archived: false)
    flag_prop = flag == :absent ? {} : { "Flag" => nl_flag(flag, flag_shape) }
    # Notion's Not A Flag Because: a text formula, "" for a flag or a closed problem.
    flag_prop["Not A Flag Because"] = nl_flag(not_a_flag_because, :text) unless not_a_flag_because == :absent
    { "object" => "page", "id" => id, "url" => "https://www.notion.so/#{id.delete('-')}",
      "created_time" => (last_seen || edited).utc.iso8601, "last_edited_time" => edited.utc.iso8601,
      "archived" => archived,
      "parent" => { "type" => "database_id", "database_id" => Stacks::Notion.filtered_parent_id(:PROBLEMS) },
      "properties" => flag_prop.merge({
        "Problem" => nl_text("title", name), "Kind" => nl_select(kind), "Severity" => nl_select(severity),
        "Status" => nl_select(status),
        "Owner" => { "type" => "people", "people" => owner ? [{ "name" => owner }] : [] },
        "Occurrences" => { "type" => "number", "number" => occurrences }, "Last Seen" => nl_date(last_seen),
        "First Seen" => nl_date(first_seen), "Proposed Action" => nl_text("rich_text", proposed_action),
        "Project" => nl_relation(project_ids), "Source Observations" => nl_relation(source_observation_ids),
      }) }
  end

  def store_log_row!(data, key, wrapper, synced_at: Time.zone.now)
    NotionPage.create!(
      notion_id: data["id"], notion_parent_type: "database_id",
      notion_parent_id: Stacks::Notion.filtered_parent_id(key),
      page_title: Stacks::Notion::Props.text(data, key == :OBSERVATIONS ? "Name" : "Problem", "title"),
      data: data, project_ids: wrapper.project_ids_in(data), occurred_at: wrapper.occurred_at_in(data),
      synced_at: synced_at
    )
  end

  def observation!(synced_at: Time.zone.now, **attrs)
    store_log_row!(observation_data(**attrs), :OBSERVATIONS, Stacks::Notion::Observation, synced_at: synced_at)
  end

  def problem!(synced_at: Time.zone.now, **attrs)
    store_log_row!(problem_data(**attrs), :PROBLEMS, Stacks::Notion::Problem, synced_at: synced_at)
  end

  def project_page!(title: "Harvey")
    NotionPage.create!(
      notion_id: SecureRandom.uuid, notion_parent_type: "database_id",
      notion_parent_id: Stacks::Utils.dashify_uuid(Stacks::Notion::DATABASE_IDS[:PROJECTS]), page_title: title,
      data: { "last_edited_time" => Time.zone.now.iso8601,
              "properties" => { "Stage" => { "type" => "select", "select" => { "name" => "Active" } } } }
    )
  end

  # A tracker filed under one new Notion project. Returns [tracker, project id].
  def log_tracker!(name: "Log Tracker #{SecureRandom.hex(2)}", project: project_page!)
    pt = ProjectTracker.new(name: name, notion_project_ids: project ? [project.notion_id] : [])
    pt.save!(validate: false)
    [pt, project&.notion_id]
  end

  # Answers the two calls the filtered sync makes. pages: database id =>
  # an array of result pages (each an array of rows). by_id: page id => row.
  # It does not apply the filter: tests assert on the filter it was sent.
  class FakeNotion
    attr_reader :queries, :fetched

    # fail_ids: page ids whose fetch raises, as a page id Notion rejects does.
    def initialize(pages: {}, by_id: {}, fail_on_page: nil, fail_ids: [])
      @pages = pages
      @by_id = by_id
      @fail_on_page = fail_on_page
      @fail_ids = fail_ids
      @queries = []
      @fetched = []
    end

    def query_database_filtered(database_id, filter:, sorts: nil, start_cursor: nil, page_size: 100)
      @queries << { database_id: database_id, filter: filter, sorts: sorts, start_cursor: start_cursor, page_size: page_size }
      batches = @pages.fetch(database_id, [[]])
      i = start_cursor.to_i
      raise Stacks::Notion::Error.new("Notion query failed (500)", status: 500) if @fail_on_page == i
      more = i + 1 < batches.size
      { "results" => batches[i].map(&:deep_dup), "next_cursor" => (more ? (i + 1).to_s : nil), "has_more" => more }
    end

    def fetch_page(page_id)
      @fetched << page_id
      raise Stacks::Notion::Error.new("Notion fetch of page #{page_id} failed (400): bad id", status: 400) if @fail_ids.include?(page_id)
      body = @by_id[page_id]
      body ? { status: 200, body: body.deep_dup } : { status: 404, body: { "code" => "object_not_found" } }
    end
  end
end

class Module
  # Swap a constant for the length of a block (tests only).
  def stub_const(name, value)
    original = const_get(name)
    silence_warnings { const_set(name, value) }
    yield
  ensure
    silence_warnings { const_set(name, original) }
  end
end
