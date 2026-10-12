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
    column("Subject") { |ws| ws.document.title }
    column("Sender") { |ws| ws.sent_by_name || ws.sent_by_email }
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
  show title: proc { |ws| ws.document.title } do
    grade = resource.grade
    email_url = resource.document.google_groups_permalink
    muted = "opacity: 0.6;"

    attributes_table do
      row("Project") { |ws| link_to ws.project_tracker.name, admin_project_tracker_path(ws.project_tracker) }
      row("Sent") { |ws| "#{ws.sent_by_name.presence || ws.sent_by_email}, #{time_ago_in_words(ws.sent_at)} ago (#{ws.sent_at.strftime("%B %-d, %Y")})" }
      row("Grade") do |_ws|
        if grade
          span WeeklyShip.stars_label(grade["stars"]), style: "font-size: 1.4em; white-space: nowrap;"
          span "#{grade["stars"]} of 5", style: "margin-left: 8px; #{muted}"
        else
          span "Not graded", style: muted
        end
      end
      row("The ship") { |_ws| link_to("Open the email ↗", email_url, target: "_blank", rel: "noopener") if email_url }
    end

    if grade
      panel "What this ship does well" do
        para grade["summary"], style: "margin: 12px; font-size: 1.1em;"
      end

      panel "For next time" do
        ol(style: "margin: 12px 12px 12px 32px; font-size: 1.1em; line-height: 1.5;") do
          Array(grade["suggestions"]).each { |s| li s, style: "margin-bottom: 8px;" }
        end
      end

      panel "How it scored" do
        rows = Stacks::WeeklyShips::Grader::GUIDE.map { |key, guide| [key, guide, (grade["dimensions"] || {})[key]] }
        table_for rows.select { |_, _, scored| scored } do
          column("A great ship") do |(_, guide, _)|
            div strong(guide[:label])
            div guide[:good], style: "#{muted} font-size: 0.9em;"
          end
          column("This ship") do |(key, _, scored)|
            if key == "continuity" && grade["continuity_counted"] == false
              span "First ship, not counted", class: "pill"
            else
              words, pill = Stacks::WeeklyShips::Grader::SCORE_LABELS.fetch(scored["score"].to_i.clamp(0, 2))
              span words, class: "pill #{pill}"
            end
          end
          column("Why") { |(key, _, scored)| scored["why"] unless key == "continuity" && grade["continuity_counted"] == false }
        end
      end
    else
      panel "Not graded" do
        para "Ships are graded overnight, the night they are linked to a project. " \
             "A ship sent more than #{Stacks::WeeklyShips::Grader::WINDOW.in_days.to_i} days before grading was switched on has no grade.",
             style: "margin: 12px;"
      end
    end

    if (previous = resource.previous_ship)
      panel "Previous ship" do
        div(style: "margin: 12px;") do
          span link_to(previous.document.title, admin_weekly_ship_path(previous))
          span ", #{time_ago_in_words(previous.sent_at)} ago", style: muted
          if (pg = previous.grade)
            span WeeklyShip.stars_label(pg["stars"]), style: "margin-left: 8px; white-space: nowrap;"
          end
        end
      end
    end

    para em("This is coaching for the Project Lead who sent the ship, scored overnight by a model against the weekly ship rubric. Never share it with the client."),
         style: "margin: 8px 12px; #{muted} font-size: 0.85em;"

    panel "How this email was linked to the project", style: muted do
      attributes_table_for resource do
        row(:matched_by)
        row(:confidence)
        row(:rationale)
      end
    end
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
