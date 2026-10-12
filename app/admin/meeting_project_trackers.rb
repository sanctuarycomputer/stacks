ActiveAdmin.register MeetingProjectTracker do
  # Menu-less: the Meeting Matches page (app/admin/meeting_project_scans.rb)
  # is the entry point; this resource adds and removes one meeting's project
  # links. Saving here never sets via_matcher, so the model treats the change
  # as a person's and locks the meeting's scan.
  menu false

  actions :new, :create, :destroy

  permit_params :meeting_id, :project_tracker_id

  controller do
    before_action :require_readable_meeting, only: [:new, :create]

    # After a link is added or removed, land back on the Meeting Matches page.
    def smart_resource_url
      admin_meeting_project_scans_path
    end

    def smart_collection_url
      admin_meeting_project_scans_path
    end

    private

    # A meeting with no document in the corpus is private: it cannot be linked
    # here, and nothing about it (not even its title) is rendered.
    def require_readable_meeting
      meeting_id = params[:meeting_id].presence || params.dig(:meeting_project_tracker, :meeting_id)
      meeting = Meeting.find_by(id: meeting_id)
      return if meeting && meeting.eligible_documents.exists?
      redirect_to admin_meeting_project_scans_path,
                  alert: "That meeting has no document in Stacks search, so it cannot be linked to a project."
    end
  end

  form title: "Add a project to a meeting" do |f|
    meeting = Meeting.find_by(id: params[:meeting_id].presence || f.object.meeting_id)
    title = meeting&.eligible_title ||
            "Meeting, #{meeting&.started_at&.strftime("%B %-d, %Y") || "date unknown"}"

    f.semantic_errors
    f.inputs do
      li do
        label "Meeting", class: "label"
        span title
      end
      f.input :meeting_id, as: :hidden, input_html: { value: meeting&.id }
      f.input :project_tracker, as: :select,
        collection: ProjectTracker.where(work_completed_at: nil).order(:name).pluck(:name, :id)
    end
    f.actions do
      f.action :submit, label: "Add project"
      # Not f.cancel_link's default: this resource has no index route.
      f.cancel_link(admin_meeting_project_scans_path)
    end
  end
end
