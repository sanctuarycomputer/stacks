ActiveAdmin.register ShipScan do
  menu label: "Ship Scans", parent: "project_trackers"

  actions :index, :show

  controller do
    def scoped_collection
      super.includes(:document)
    end
  end

  scope("Needs Review", default: true) { |s| s.no_match.where(human_locked: false) }
  scope :all

  filter :outcome, as: :select, collection: ShipScan.outcomes
  filter :human_locked
  filter :scanned_at

  index do
    column("Subject") { |scan| scan.document.title }
    column("Occurred At") { |scan| scan.document.occurred_at }
    column("Outcome") { |scan| span scan.outcome, class: "pill" }
    column :human_locked
    column :scanned_at
    column("Google Groups") do |scan|
      url = scan.document.google_groups_permalink
      link_to("Open in Google Groups ↗", url, target: "_blank", rel: "noopener") if url
    end
    column("") do |scan|
      link_to("Link manually →", new_admin_weekly_ship_path(document_id: scan.document_id))
    end
  end

  show do
    attributes_table do
      row("Subject") { |scan| scan.document.title }
      row("Occurred At") { |scan| scan.document.occurred_at }
      row("Outcome") { |scan| span scan.outcome, class: "pill" }
      row :human_locked
      row :scanned_at
      row("Google Groups") do |scan|
        url = scan.document.google_groups_permalink
        link_to("Open in Google Groups ↗", url, target: "_blank", rel: "noopener") if url
      end
    end
  end
end
