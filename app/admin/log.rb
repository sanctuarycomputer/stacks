# The project log: what Stacksbot has seen about a project, at
# /admin/project_trackers/:id/log. Stacks only filters and draws rows the
# filtered Notion sync stored (Stacks::ProjectLog); every judgement in them is
# Stacksbot's. Read-only: triage stays in Notion.
#
# Who may read it: whoever may read the tracker. ActiveAdmin checks the page
# itself first (AdminAuthorization lets admins, leads and anyone holding a
# project-scoped lead grant through), then load_and_authorize_tracker checks
# this tracker, which is what limits a grantee to their own.
ActiveAdmin.register_page "Log" do
  belongs_to :project_tracker
  menu false

  controller do
    before_action :refuse_other_formats
    before_action :load_and_authorize_tracker

    # The content block is Arbre and does not see controller ivars, so the
    # two things it needs are helpers (as in app/admin/project_trackers.rb).
    helper_method :log_tracker, :project_log

    def log_tracker
      @log_tracker
    end

    # Only these four parameters are read, and each is whitelisted inside
    # Stacks::ProjectLog. A registered page runs no Ransack, so ?q and ?order
    # do nothing here.
    def project_log
      @project_log ||= Stacks::ProjectLog.new(
        @log_tracker, view: params[:view], source: params[:source], valence: params[:valence], page: params[:page]
      )
    end

    private

    # HTML only: there is no CSV, JSON or XML form of the log.
    def refuse_other_formats
      raise ActionController::UnknownFormat unless request.format&.html?
    end

    def load_and_authorize_tracker
      @log_tracker = ProjectTracker.find(params[:project_tracker_id])
      authorize! :read, @log_tracker
    end
  end

  content title: "Project Log" do
    render(partial: "show", locals: { tracker: log_tracker, log: project_log })
  end
end
