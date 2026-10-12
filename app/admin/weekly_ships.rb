ActiveAdmin.register WeeklyShip do
  # Menu-less: the unified per-email page (app/admin/ship_scans.rb, labeled
  # "Weekly Ships") is the entry point; this resource provides the link-level
  # CRUD (new/edit/destroy/show) reached from there.
  menu false

  permit_params :document_id, :project_tracker_id, :sent_at

  controller do
    def scoped_collection
      super.includes(:document, :project_tracker)
    end

    # After link-level writes, land back on the unified Weekly Ships page
    # rather than this menu-less resource.
    def smart_resource_url
      admin_ship_scans_path
    end

    def smart_collection_url
      admin_ship_scans_path
    end
  end

  filter :project_tracker
  filter :matched_by, as: :select, collection: WeeklyShip.matched_bies
  filter :sent_at

  index do
    selectable_column
    column("Subject") { |ws| ws.display_title }
    column("Sender") { |ws| ws.sender_label }
    column :sent_at
    column :project_tracker
    column("Matched By") { |ws| span ws.matched_by, class: "pill" }
    column :confidence
    column("Google Groups") do |ws|
      url = ws.document.google_groups_permalink
      link_to("Open ↗", url, target: "_blank", rel: "noopener") if url
    end
    actions
  end

  # The coaching page for a ship's sender: what worked, what to add next time,
  # then how it scored against the rubric (Stacks::WeeklyShips::Grader), in the
  # words a Project Lead would use. Never shown to the client.
  show title: proc { |ws| ws.display_title } do
    grader = Stacks::WeeklyShips::Grader
    # Laid out in app/views/admin/weekly_ships/_show.html.erb, in the same
    # modules as the Project Tracker page.
    # A link added after the email was graded has no grade of its own (the
    # grader copies it over only inside its window), so read the email's grade
    # from any row.
    grade = resource.grade || WeeklyShip.where(document_id: resource.document_id).filter_map(&:grade).first
    previous = resource.previous_ship
    # Stored grades are model output: show only the parts that have the right shape.
    suggestions = grade ? Array(grade["suggestions"]).select { |s| s.is_a?(String) && s.present? } : []
    dimensions = grade && grade["dimensions"].is_a?(Hash) ? grade["dimensions"] : {}
    scored_rows = grader::GUIDE.filter_map do |key, guide|
      scored = dimensions[key]
      [key, guide, scored] if scored.is_a?(Hash) && scored["score"].is_a?(Integer) && scored["score"].between?(0, 2)
    end
    continuity_not_counted = grade && grade["continuity_counted"] == false

    render(partial: "show", locals: {
      weekly_ship: resource, grade: grade, previous: previous, suggestions: suggestions,
      scored_rows: scored_rows, continuity_not_counted: continuity_not_counted,
    })
  end

  form do |f|
    # Build base collection: newest 200 corpus-eligible ships_group documents.
    base = Document.ships_group.corpus_eligible.order(occurred_at: :desc).limit(200)
    # Always include the pre-selected doc (from params) and the current record's doc,
    # even if they've aged out of the newest-200 window.
    pinned_ids = [params[:document_id], f.object.document_id].compact.map(&:to_i).uniq
    pinned_docs = pinned_ids.any? ? Document.ships_group.corpus_eligible.where(id: pinned_ids) : Document.none
    doc_collection = (base.to_a + pinned_docs.to_a).uniq(&:id)
                       .sort_by { |d| d.occurred_at || Time.zone.at(0) }
                       .reverse
                       .map { |d| [d.title, d.id] }
    selected_doc_id = (params[:document_id] || f.object.document_id).presence

    f.inputs do
      f.input :document, as: :select,
        collection: doc_collection,
        selected: selected_doc_id
      f.input :project_tracker, as: :select,
        collection: ProjectTracker.where(work_completed_at: nil).order(:name).pluck(:name, :id)
      f.input :sent_at
    end
    f.actions
  end

  # Human creates via this form get sent_at defaulted from the document and
  # matched_by :human via the model callback chain.
  before_save do |ship|
    ship.sent_at ||= ship.document&.occurred_at
  end
end
