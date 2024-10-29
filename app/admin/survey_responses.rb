ActiveAdmin.register SurveyResponse do
  config.filters = false
  config.paginate = false
  menu false
  actions :index, :new, :show, :create, :delete
  permit_params :survey_id,
    survey_question_responses_attributes: [
      :id,
      :survey_question_id,
      :sentiment,
      :context,
      :_destroy,
      :_edit
    ],
    survey_free_text_question_responses_attributes: [
      :id,
      :survey_free_text_question_id,
      :response,
      :_destroy,
      :_edit
    ]

    controller do
      def new
        build_resource
        survey = Survey.find(params["survey_id"])

        if SurveyResponder.find_by(survey_id: survey.id, admin_user_id: current_admin_user.id)
          return redirect_to admin_survey_path(survey)
        end

        raise if survey.status != :open

        # TODO: raise if survey has responder for this admin_user
        resource.survey = survey
        survey.survey_questions.each do |sq|
          resource.survey_question_responses << SurveyQuestionResponse.new({
            survey_question: sq
          })
        end
        survey.survey_free_text_questions.each do |sftq|
          resource.survey_free_text_question_responses << SurveyFreeTextQuestionResponse.new({
            survey_free_text_question: sftq
          })
        end
        new!
      end

      def create
        if SurveyResponder.find_by(survey_id: params["survey_response"]["survey_id"], admin_user_id: current_admin_user.id)
          return redirect_to admin_survey_path(params["survey_response"]["survey_id"])
        end

        super do |success,failure|
          success.html {
            SurveyResponder.create!({
              admin_user: current_admin_user,
              survey: resource.survey
            })
            redirect_to admin_survey_path(resource.survey)
          }
        end
      end
    end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.semantic_errors
      f.input :survey, collection: [f.object.survey], include_blank: false

      f.has_many :survey_question_responses, heading: false, allow_destroy: false, new_record: false do |a|
        a.input :survey_question, input_html: { class: "display_only" }, collection: [a.object.survey_question], include_blank: false
        a.input :sentiment, as: :radio
        a.input :context, as: :text, label: "Additional Context", placeholder: "(Optional) Add an explaination for your score"
      end

      f.has_many :survey_free_text_question_responses, heading: false, allow_destroy: false, new_record: false do |a|
        a.input :survey_free_text_question, input_html: { class: "display_only" }, collection: [a.object.survey_free_text_question], include_blank: false
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
          .querySelector('li#survey_response_submit_action input[type="submit"]')
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
