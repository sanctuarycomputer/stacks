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
    # A link added after the email was graded has no grade of its own until the
    # next nightly run copies it over, so read the email's grade from any row.
    grade = resource.grade || WeeklyShip.where(document_id: resource.document_id).filter_map(&:grade).first
    previous = resource.previous_ship
    email_url = resource.document.google_groups_permalink
    muted = "opacity: 0.6;"
    # Stored grades are model output: show only the parts that have the right shape.
    suggestions = grade ? Array(grade["suggestions"]).select { |s| s.is_a?(String) && s.present? } : []
    dimensions = grade && grade["dimensions"].is_a?(Hash) ? grade["dimensions"] : {}
    scored_rows = grader::GUIDE.filter_map do |key, guide|
      scored = dimensions[key]
      [key, guide, scored] if scored.is_a?(Hash) && scored["score"].is_a?(Integer) && scored["score"].between?(0, 2)
    end
    continuity_not_counted = grade && grade["continuity_counted"] == false

    attributes_table title: "This ship" do
      row("Project") { |ws| link_to ws.project_tracker.name, admin_project_tracker_path(ws.project_tracker) }
      row("Sent") { |ws| "#{ws.sender_label}, #{time_ago_in_words(ws.sent_at)} ago (#{ws.sent_at.strftime("%B %-d, %Y")})" }
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
      if grade["summary"].present?
        panel "What this ship does well" do
          para grade["summary"].to_s, style: "margin: 12px; font-size: 16px;"
        end
      end

      if suggestions.any?
        panel "For next time" do
          ol(style: "margin: 12px 12px 12px 32px; font-size: 16px; line-height: 1.5;") do
            # list-style on each item: the admin reset strips the numbers off an ol.
            suggestions.each { |s| li s, style: "margin-bottom: 8px; list-style: decimal;" }
          end
        end
      end

      if scored_rows.any?
        panel "How it scored" do
          table_for scored_rows do
            column("A great ship") do |(_, guide, _)|
              div strong(guide[:label])
              div guide[:good], style: "#{muted} font-size: 0.9em;"
            end
            column("This ship") do |(key, _, scored)|
              if key == "continuity" && continuity_not_counted
                # A bare .pill has no background, so the grey is set here.
                span previous ? "Not counted" : "First ship, not counted", class: "pill", style: "background-color: #e3e5e7;"
              else
                words, pill = grader::SCORE_LABELS.fetch(scored["score"])
                span words, class: "pill #{pill}"
              end
            end
            column("Why") { |(key, _, scored)| scored["why"].to_s unless key == "continuity" && continuity_not_counted }
          end
        end
      end
    else
      panel "Not graded" do
        days = grader::WINDOW.in_days.to_i
        why =
          if !resource.document.corpus_eligible?
            "This ship is not graded because its email is excluded from Stacks search."
          elsif resource.sent_at >= grader::WINDOW.ago
            "This ship has not been graded yet. Ships are usually graded overnight once they are linked to a project."
          else
            "This ship has no grade. Only ships sent in the last #{days} days are graded, and this one was " \
              "older than that when it was linked or when grading began."
          end
        para why, style: "margin: 12px; font-size: 16px;"
      end
    end

    if previous
      panel "Previous ship" do
        div(style: "margin: 12px;") do
          # The previous ship can be on another project this email is linked to.
          elsewhere = ", on #{previous.project_tracker.name}" if previous.project_tracker_id != resource.project_tracker_id
          # One text node: Arbre puts each tag on its own line, which would show
          # as a space before the comma.
          text_node safe_join([
            link_to(previous.display_title, admin_weekly_ship_path(previous)),
            content_tag(:span, ", #{time_ago_in_words(previous.sent_at)} ago#{elsewhere}", style: muted),
          ])
          if (pg = previous.grade)
            span WeeklyShip.stars_label(pg["stars"]), style: "margin-left: 8px; white-space: nowrap;"
          end
        end
      end
    end

    para "This is coaching for the Project Lead who sent the ship. Stacks scores each ship overnight against " \
         "what a great ship does. Never share it with the client.",
         style: "margin: 8px 12px; font-size: 13px;"

    panel "How this email was linked to the project", style: muted do
      attributes_table_for resource do
        row("Linked by") { |ws| ws.human? ? "A person" : "Stacks (automatic)" }
        # Only the nightly sweep records a confidence.
        row("Confidence") { |ws| "#{(ws.confidence * 100).round}%" } unless resource.confidence.nil?
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
