# The unified "Weekly Ships" page. One row per ships@ email the sweep has
# examined (ShipScan is the per-email spine — every linked email has a scan
# row too), with its tracker links inline. Unlinked rows are "weekly ship
# candidates" awaiting review; the WeeklyShip resource itself is menu-less
# CRUD reached from here.
ActiveAdmin.register ShipScan do
  menu label: "Weekly Ships", parent: "project_trackers"

  actions :index, :show

  controller do
    def scoped_collection
      super.includes(document: { weekly_ships: :project_tracker })
    end
  end

  scope("Needs Review", default: true) { |s| s.no_match.where(human_locked: false) }
  scope("Linked") { |s| s.linked }
  scope("Not a Ship") { |s| s.not_a_ship }
  # Older than the 90-day backfill window — recorded but never LLM-classified
  # (their projects are mostly long-completed). Kept visible so the scope
  # counts add up to All.
  scope("Out of Scope (>90d)") { |s| s.out_of_scope }
  scope :all

  filter :outcome, as: :select, collection: ShipScan.outcomes
  filter :human_locked
  filter :scanned_at

  config.sort_order = "scanned_at_desc"

  index do
    column("Ship Email") { |scan| scan.document.title }
    column("Sent") { |scan| scan.document.occurred_at&.to_date }
    column("Trackers") do |scan|
      ships = scan.document.weekly_ships
      if ships.any?
        ships.each do |ws|
          div do
            span link_to(ws.project_tracker.name, admin_project_tracker_path(ws.project_tracker))
            span link_to("details", admin_weekly_ship_path(ws), style: "margin-left: 6px; opacity: 0.6; font-size: 0.85em;")
          end
        end
      else
        span "—", style: "opacity: 0.4;"
      end
    end
    column("Status") do |scan|
      pill_class = scan.linked? ? "pill exceptional" : "pill"
      span scan.outcome.humanize, class: pill_class
      span "🔒", title: "Human-locked — the sweep will not change this" if scan.human_locked?
    end
    column("Google Groups") do |scan|
      url = scan.document.google_groups_permalink
      link_to("Open ↗", url, target: "_blank", rel: "noopener") if url
    end
    column("") do |scan|
      label = scan.document.weekly_ships.any? ? "Add link →" : "Link →"
      link_to(label, new_admin_weekly_ship_path(document_id: scan.document_id))
    end
  end

  show do
    attributes_table do
      row("Ship Email") { |scan| scan.document.title }
      row("Sent") { |scan| scan.document.occurred_at }
      row("Outcome") { |scan| span scan.outcome.humanize, class: "pill" }
      row :human_locked
      row :scanned_at
      row("Google Groups") do |scan|
        url = scan.document.google_groups_permalink
        link_to("Open in Google Groups ↗", url, target: "_blank", rel: "noopener") if url
      end
    end

    panel "Linked Trackers" do
      ships = resource.document.weekly_ships.includes(:project_tracker)
      if ships.any?
        table_for ships do
          column("Tracker") { |ws| link_to ws.project_tracker.name, admin_project_tracker_path(ws.project_tracker) }
          column("Matched By") { |ws| ws.matched_by }
          column :confidence
          column :rationale
          column("") { |ws| link_to "Edit", edit_admin_weekly_ship_path(ws) }
        end
      else
        para em("No trackers linked."), style: "margin: 12px;"
      end
    end
  end
end
