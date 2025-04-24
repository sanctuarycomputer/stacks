ActiveAdmin.register ProjectCapsule do
  menu false
  config.filters = false
  config.sort_order = "created_at_desc"
  config.paginate = false
  actions :index, :edit, :update

  permit_params :client_feedback_survey_status,
    :client_feedback_survey_url,
    :internal_marketing_status,
    :capsule_status,
    :postpartum_notes,
    :client_satisfaction_status,
    :client_satisfaction_detail,
    :project_satisfaction_survey_status

  controller do
    def update
      super do |success,failure|
        success.html {
          redirect_to admin_project_tracker_path(resource.project_tracker_id)
        }
      end
    end
  end

  action_item :create_project_satisfaction_survey, only: [:edit] do
    if resource.project_satisfaction_survey.nil?
      link_to "Create Project Satisfaction Survey", create_project_satisfaction_survey_admin_project_capsule_path(resource), method: :post
    else
      link_to "View Project Satisfaction Survey", admin_project_satisfaction_survey_path(resource.project_satisfaction_survey)
    end
  end

  member_action :create_project_satisfaction_survey, method: :post do
    redirect_to new_admin_project_satisfaction_survey_path(project_capsule_id: resource.id), notice: "Please confirm the survey questions before creating the survey."
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.input :client_satisfaction_status
      f.input :client_satisfaction_detail,
        label: "Client Satisfaction Detail (accepts markdown) <a href='https://www.notion.so/garden3d/What-a-successful-project-is-d430681549fc40e2af5ec4b7452fd94a' target='_blank'>(Instructions ↗)</a>".html_safe,
        placeholder: "Example: The client rated their satisfaction as 4 (out of 5)"

      f.input :client_feedback_survey_status
      f.input :client_feedback_survey_url
      f.input :internal_marketing_status
      f.input :capsule_status
      f.input :project_satisfaction_survey_status
      f.input :postpartum_notes, label: "Postpartum Meeting Notes (accepts markdown)"
   end

    f.actions
  end
end
