# The project log: what Stacksbot has seen about a project, at
# /admin/project_trackers/:id/log. One page: Flags, Other open problems, Wins,
# All Observations. Stacks only filters and draws rows the filtered Notion
# sync stored (Stacks::ProjectLog); every judgement in them, what is a flag
# included, is Notion's. Read-only: triage stays in Notion.
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
    helper_method :log_tracker, :project_log, :loaded_project_log

    def log_tracker
      @log_tracker
    end

    # Only these three parameters are read, and each is whitelisted inside
    # Stacks::ProjectLog. They filter and page All Observations; the flags and
    # wins above it do not move. A registered page runs no Ransack, so ?q and
    # ?order do nothing here, and neither does the ?view of an old link.
    def project_log
      @project_log ||= Stacks::ProjectLog.new(
        @log_tracker, source: params[:source], valence: params[:valence], page: params[:page]
      )
    end

    # The log with its rows already read, or nil when they cannot be read
    # (the sync's columns are missing, say). The page then says so inside its
    # usual frame rather than answering with a 500.
    def loaded_project_log
      return @loaded_project_log if defined?(@loaded_project_log)
      @loaded_project_log =
        begin
          project_log.load!
        rescue StandardError => e
          Rails.logger.error("[project log] tracker #{@log_tracker.id} could not be read: #{e.class}: #{e.message}")
          nil
        end
    end

    private

    # HTML only: there is no CSV, JSON or XML form of the log. A request that
    # names no type, or accepts any ("Accept: */*", as curl sends), gets HTML.
    def refuse_other_formats
      return if request.format&.html?
      raise ActionController::UnknownFormat unless params[:format].blank? && request.format == Mime::ALL
      request.format = :html
    end

    def load_and_authorize_tracker
      @log_tracker = ProjectTracker.find(params[:project_tracker_id])
      authorize! :read, @log_tracker
    end
  end

  # The way back to the tracker. Breadcrumbs are off across this admin
  # (config.breadcrumb), so the page carries the link itself.
  action_item :tracker do
    link_to "← #{log_tracker.name}", admin_project_tracker_path(log_tracker), class: "log-back-to-tracker"
  end

  content title: "Project Log" do
    if loaded_project_log
      render(partial: "show", locals: { tracker: log_tracker, log: loaded_project_log })
    else
      render(partial: "unavailable", locals: { tracker: log_tracker })
    end
  end
end
