ActiveAdmin.register WeeklyShip do
  menu label: "Weekly Ships", parent: "Projects", if: -> { true }

  permit_params :document_id, :project_tracker_id, :sent_at

  controller do
    def scoped_collection
      super.includes(:document, :project_tracker)
    end
  end

  filter :project_tracker
  filter :matched_by, as: :select, collection: WeeklyShip.matched_bies.keys
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

  show do
    attributes_table do
      row("Subject") { |ws| ws.document.title }
      row(:project_tracker)
      row("Sender") { |ws| "#{ws.sent_by_name} <#{ws.sent_by_email}>" }
      row(:sent_at)
      row(:matched_by)
      row(:confidence)
      row(:rationale)
      row("Google Groups") do |ws|
        url = ws.document.google_groups_permalink
        link_to("Open in Google Groups ↗", url, target: "_blank", rel: "noopener") if url
      end
    end
  end

  form do |f|
    f.inputs do
      f.input :document, as: :select,
        collection: Document.ships_group.order(occurred_at: :desc).limit(200).map { |d| [d.title, d.id] }
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
