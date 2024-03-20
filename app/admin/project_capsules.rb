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
    :client_satisfaction_detail

  controller do
    def update
      super do |success,failure|
        success.html {
          redirect_to admin_project_tracker_path(resource.project_tracker_id)
        }
      end
    end
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
      f.input :postpartum_notes, label: "Postpartum Meeting Notes (accepts markdown)"
   end

    f.actions
  end
end
