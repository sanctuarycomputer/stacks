ActiveAdmin.register_page "Project Cost Explorer" do
  belongs_to :project_tracker

  content title: "Project Cost Explorer" do
    render(partial: "show", locals: {
      monthly_cosr: ProjectTracker.find(params[:project_tracker_id]).monthly_cosr
    })
  end
end