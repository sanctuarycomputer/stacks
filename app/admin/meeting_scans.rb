# The "Meeting Matches" page, the sibling of "Weekly Ships"
# (app/admin/ship_scans.rb). One row per Google Meet meeting the nightly sweep
# (Stacks::Meetings::Sweep) has examined, with the project tracker(s) it is
# linked to inline. MeetingScan is the per-meeting spine and holds the model's
# confidence and reason; the links are a plain join table with no resource of
# their own, so a person adds and removes them with the two member actions
# here, and either one locks the meeting (Meeting#link_project! and
# #unlink_project!).
#
# Privacy: only meetings with a document in the Stacks corpus are listed, and
# everything shown about a meeting (title, link) comes from those documents.
ActiveAdmin.register MeetingScan do
  menu label: "Meeting Matches", parent: "project_trackers"

  actions :index

  # The default filters would offer a list of every meeting's title, private ones included.
  config.filters = false
  config.sort_order = "meetings.started_at_desc"

  controller do
    before_action :find_meeting_to_change, only: [:add_project, :remove_project]

    def scoped_collection
      super.joins(:meeting)
           .where(meeting_id: Meeting.joins(:documents).merge(Document.corpus_eligible).select(:id))
           .includes(meeting: [:documents, :project_trackers])
    end

    # No filtering and no sorting by request. With the sidebar hidden,
    # ActiveAdmin still applies ?q[...] and ?order=..., and a search over the
    # meeting's segments, titles or the stored reason would answer yes or no
    # about text that is excluded from the corpus. The parameters are dropped
    # before ActiveAdmin reads them.
    before_action(only: :index) do
      params.delete(:q)
      params.delete(:order)
    end

    private

    # ActiveAdmin authorizes a member action only when the action loads
    # `resource`, and these do not (scoped_collection would 404 a meeting with
    # no eligible document instead of saying so). So the check is made here,
    # first, with the action's own name as ActiveAdmin would pass it:
    # AdminAuthorization lets admins and leads through and refuses a
    # project-scoped lead grantee, as it does for ShipScan.
    def find_meeting_to_change
      @scan = MeetingScan.find_by(id: params[:id])
      authorize! action_to_permission(params[:action]), @scan || MeetingScan
      @meeting = @scan&.meeting
      # A meeting with no document in the corpus is private: it cannot be
      # changed here, and nothing about it (not even its title) is rendered.
      return if @meeting && @meeting.eligible_documents.exists?
      redirect_to admin_meeting_scans_path,
                  alert: "That meeting has no document in Stacks search, so its projects cannot be changed here."
    end
  end

  # Unmatched, or matched without much confidence, and not yet settled by a person.
  scope("Needs Review", default: true) do |s|
    s.where(human_locked: false)
     .where("meeting_scans.outcome = 1 OR (meeting_scans.outcome = 0 AND meeting_scans.confidence < 0.8)")
  end
  scope("Linked") { |s| s.linked }
  scope("No Match") { |s| s.no_match }
  # Also holds the meetings older than the sweep's 90-day window (out_of_scope):
  # recorded, never sent to the model.
  scope :all

  # download_links: false also refuses the .csv, .json and .xml forms of this
  # page, which would hand out the raw reason column whatever the page hides.
  index title: "Meeting Matches", download_links: false do
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
    column("Held") { |scan| scan.meeting.started_at&.to_date }
    column("Projects") do |scan|
      trackers = scan.meeting.project_trackers.sort_by(&:id)
      if trackers.any?
        trackers.each do |tracker|
          div do
            a(tracker.name, href: admin_project_tracker_path(tracker), style: "font-size: inherit;")
            a("×", href: remove_project_admin_meeting_scan_path(scan, project_tracker_id: tracker.id),
              title: "Remove this project from the meeting",
              "data-method": "delete",
              "data-confirm": "Remove #{tracker.name} from this meeting? Stacks will leave the meeting as you set it.",
              style: "margin-left: 6px; text-decoration: none; font-size: inherit;")
          end
        end
      else
        span "—", style: "opacity: 0.4;"
      end
    end
    column("Confidence") { |scan| "#{(scan.confidence * 100).round}%" if scan.confidence }
    column("Why") do |scan|
      # The reason was written from the documents the sweep read. Once those
      # have changed (one was excluded, say), it is no longer shown.
      # Hashed from the documents already loaded for the row, not queried per row.
      docs = scan.meeting.documents.select(&:corpus_eligible?)
      span scan.rationale if scan.scanned_hash.present? && scan.scanned_hash == Meeting.content_hash_for(docs)
    end
    column("Decided by") { |scan| scan.human_locked? ? "A person" : "Stacks (automatic)" }
    column("") do |scan|
      a("Add a project", href: add_project_admin_meeting_scan_path(scan), style: "font-size: inherit;")
    end
  end

  # GET shows a small form (app/views/admin/meeting_scans/add_project.html.erb);
  # POST links the chosen tracker.
  member_action :add_project, method: [:get, :post] do
    if request.get?
      @page_title = "Add a project to a meeting"
      @meeting_title = @meeting.eligible_title ||
                       "Meeting, #{@meeting.started_at&.strftime("%B %-d, %Y") || "date unknown"}"
      @trackers = ProjectTracker.where(work_completed_at: nil).order(:name).pluck(:name, :id)
      next render("admin/meeting_scans/add_project")
    end

    tracker = ProjectTracker.find_by(id: params[:project_tracker_id])
    next redirect_to(add_project_admin_meeting_scan_path(@scan), alert: "Choose a project to add.") if tracker.nil?
    begin
      @meeting.link_project!(tracker)
    rescue ActiveRecord::RecordInvalid
      # Its last eligible document was excluded since the check above.
      next redirect_to(admin_meeting_scans_path,
                       alert: "That meeting has no document in Stacks search, so its projects cannot be changed here.")
    end
    redirect_to admin_meeting_scans_path, notice: "#{tracker.name} was added to the meeting."
  end

  member_action :remove_project, method: :delete do
    tracker = ProjectTracker.find_by(id: params[:project_tracker_id])
    @meeting.unlink_project!(tracker) if tracker
    redirect_to admin_meeting_scans_path, notice: tracker ? "#{tracker.name} was removed from the meeting." : nil
  end
end
