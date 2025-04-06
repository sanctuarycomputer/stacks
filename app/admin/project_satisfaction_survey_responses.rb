ActiveAdmin.register ProjectSatisfactionSurveyResponse do
  config.filters = false
  config.paginate = false
  menu false
  actions :index, :new, :show, :create, :delete
  permit_params :project_satisfaction_survey_id,
    project_satisfaction_survey_question_responses_attributes: [
      :id,
      :project_satisfaction_survey_question_id,
      :sentiment,
      :context,
      :_destroy,
      :_edit
    ],
    project_satisfaction_survey_free_text_question_responses_attributes: [
      :id,
      :project_satisfaction_survey_free_text_question_id,
      :response,
      :_destroy,
      :_edit
    ]

    controller do
      def new
        build_resource
        project_satisfaction_survey = ProjectSatisfactionSurvey.find(params["project_satisfaction_survey_id"])

        if ProjectSatisfactionSurveyResponder.find_by(project_satisfaction_survey_id: project_satisfaction_survey.id, admin_user_id: current_admin_user.id)
          return redirect_to admin_project_satisfaction_survey_path(project_satisfaction_survey)
        end

        raise if project_satisfaction_survey.status != :open

        # Build the response with questions
        resource.project_satisfaction_survey = project_satisfaction_survey
        project_satisfaction_survey.project_satisfaction_survey_questions.each do |sq|
          resource.project_satisfaction_survey_question_responses << ProjectSatisfactionSurveyQuestionResponse.new({
            project_satisfaction_survey_question: sq
          })
        end
        project_satisfaction_survey.project_satisfaction_survey_free_text_questions.each do |sftq|
          resource.project_satisfaction_survey_free_text_question_responses << ProjectSatisfactionSurveyFreeTextQuestionResponse.new({
            project_satisfaction_survey_free_text_question: sftq
          })
        end
        new!
      end

      def create
        if ProjectSatisfactionSurveyResponder.find_by(project_satisfaction_survey_id: params["project_satisfaction_survey_response"]["project_satisfaction_survey_id"], admin_user_id: current_admin_user.id)
          return redirect_to admin_project_satisfaction_survey_path(params["project_satisfaction_survey_response"]["project_satisfaction_survey_id"])
        end

        super do |success,failure|
          success.html {
            ProjectSatisfactionSurveyResponder.create!({
              admin_user: current_admin_user,
              project_satisfaction_survey: resource.project_satisfaction_survey
            })
            redirect_to admin_project_satisfaction_survey_path(resource.project_satisfaction_survey)
          }
        end
      end
    end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.semantic_errors
      f.input :project_satisfaction_survey, collection: [f.object.project_satisfaction_survey], include_blank: false

      f.has_many :project_satisfaction_survey_question_responses, heading: false, allow_destroy: false, new_record: false do |a|
        a.input :project_satisfaction_survey_question, input_html: { class: "display_only" }, collection: [a.object.project_satisfaction_survey_question], include_blank: false
        a.input :sentiment, as: :radio
        a.input :context, as: :text, label: "Additional Context", placeholder: "(Optional) Add an explanation for your score"
      end

      f.has_many :project_satisfaction_survey_free_text_question_responses, heading: false, allow_destroy: false, new_record: false do |a|
        a.input :project_satisfaction_survey_free_text_question, input_html: { class: "display_only" }, collection: [a.object.project_satisfaction_survey_free_text_question], include_blank: false
        a.input :response, as: :text, label: "Response", placeholder: "(Optional) Let us know what you think"
      end

      f.actions

      script (<<-JS
        var buttons = document.querySelectorAll('a.button.has_many_remove');
        for (let i = 0; i < buttons.length; i++) {
          var button = buttons[i];
          button.parentNode.remove();
        }

        document
          .querySelector('li#project_satisfaction_survey_response_submit_action input[type="submit"]')
          .addEventListener("click", function(e){
            if(!confirm("Are you sure you're ready? Due to the anonymous nature of this form, you'll not be able to edit or resubmit these responses — they're final.")){
              e.preventDefault();
            }
          });
      JS
      ).html_safe
    end
  end
end