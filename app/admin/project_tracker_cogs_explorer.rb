ActiveAdmin.register_page "Project Tracker COGS Explorer" do
  belongs_to :project_tracker

  content title: proc { I18n.t("active_admin.project_tracker_cogs_explorer") } do

    project_tracker = ProjectTracker.find(params[:project_tracker_id])
    render(partial: "project_tracker_cogs_explorer", locals: {
      project_tracker: project_tracker
    })
  end
end
