# The "Meeting Matches" page. One row per Google Meet meeting the nightly
# matcher (Stacks::Meetings::ProjectMatcher) has examined, with the project
# tracker(s) it was matched to inline. MeetingProjectScan is the per-meeting
# spine; the links themselves (MeetingProjectTracker) are menu-less CRUD
# reached from here, and any change a person makes there locks the meeting.
#
# Privacy: only meetings with a document in the Stacks corpus are listed, and
# everything shown about a meeting (title, link) comes from those documents.
ActiveAdmin.register MeetingProjectScan do
  menu label: "Meeting Matches", parent: "project_trackers"

  actions :index

  # The default filters would offer a list of every meeting's title, private ones included.
  config.filters = false
  config.sort_order = "meetings.started_at_desc"

  controller do
    def scoped_collection
      super.joins(:meeting)
           .where(meeting_id: Meeting.joins(:documents).merge(Document.corpus_eligible).select(:id))
           .includes(meeting: [:documents, { meeting_project_trackers: :project_tracker }])
    end
  end

  # Unmatched, or matched without much confidence, and not yet settled by a person.
  scope("Needs Review", default: true) do |s|
    s.where(human_locked: false)
     .where("meeting_project_scans.outcome = 1 OR EXISTS (SELECT 1 FROM meeting_project_trackers l " \
            "WHERE l.meeting_id = meeting_project_scans.meeting_id AND l.confidence < 0.8)")
  end
  scope("Linked") { |s| s.linked }
  scope("No Match") { |s| s.no_match }
  scope :all

  index title: "Meeting Matches" do
    column("Meeting") do |scan|
      docs = Meeting.notes_first(scan.meeting.documents.select(&:corpus_eligible?))
      title = scan.meeting.eligible_title(docs) ||
              "Meeting, #{scan.meeting.started_at&.strftime("%B %-d, %Y") || "date unknown"}"
      url = docs.map(&:url).find(&:present?)
      if url
        a(title, href: url, target: "_blank", rel: "noopener", style: "font-size: inherit;")
      else
        span title
      end
    end
    column("Held", sortable: "meetings.started_at") { |scan| scan.meeting.started_at&.to_date }
    column("Projects") do |scan|
      links = scan.meeting.meeting_project_trackers.sort_by(&:id)
      if links.any?
        links.each do |link|
          div do
            a(link.project_tracker.name, href: admin_project_tracker_path(link.project_tracker), style: "font-size: inherit;")
            span "#{(link.confidence * 100).round}%", style: "margin-left: 6px; opacity: 0.6;" if link.confidence
            a("×", href: admin_meeting_project_tracker_path(link), title: "Remove this project from the meeting",
              "data-method": "delete",
              "data-confirm": "Remove #{link.project_tracker.name} from this meeting? Stacks will leave the meeting as you set it.",
              style: "margin-left: 6px; text-decoration: none; font-size: inherit;")
          end
        end
      else
        span "—", style: "opacity: 0.4;"
      end
    end
    column("Why") do |scan|
      # The reason was written from the documents the matcher read. Once those
      # have changed (one was excluded, say), it is no longer shown.
      # Hashed from the documents already loaded for the row, not queried per row.
      docs = scan.meeting.documents.select(&:corpus_eligible?)
      if scan.scanned_hash.present? && scan.scanned_hash == Meeting.content_hash_for(docs)
        rationale = scan.meeting.meeting_project_trackers.sort_by(&:id).map(&:rationale).find(&:present?)
        span rationale if rationale
      end
    end
    column("Decided by") { |scan| scan.human_locked? ? "A person" : "Stacks (automatic)" }
    column("") do |scan|
      a("Add a project", href: new_admin_meeting_project_tracker_path(meeting_id: scan.meeting_id), style: "font-size: inherit;")
    end
  end
end
