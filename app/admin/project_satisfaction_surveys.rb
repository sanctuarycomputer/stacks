ActiveAdmin.register ProjectSatisfactionSurvey do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :create, :edit, :update, :delete
  menu label: "Project Satisfaction Surveys", parent: "All Surveys", priority: 2

  scope :open, default: true
  scope :closed
  scope :all

  permit_params :title,
    :description,
    :project_capsule_id,
    project_satisfaction_survey_questions_attributes: [
      :id,
      :project_satisfaction_survey_id,
      :prompt,
      :_destroy,
      :_edit
    ],
    project_satisfaction_survey_free_text_questions_attributes: [
      :id,
      :project_satisfaction_survey_id,
      :prompt,
      :_destroy,
      :_edit
    ]

  action_item :close_survey, only: [:show, :edit] do
    if resource.status == :open
      link_to "Close Survey", close_survey_admin_project_satisfaction_survey_path(resource), method: :post
    end
  end

  action_item :reopen_survey, only: [:show, :edit] do
    if resource.status == :closed
      link_to "Reopen Survey", reopen_survey_admin_project_satisfaction_survey_path(resource), method: :post
    end
  end

  member_action :close_survey, method: :post do
    resource.update!({ closed_at: DateTime.now })

    # The project_satisfaction_survey_status_valid? method in ProjectCapsule
    # automatically checks the closed? status of the survey, so we don't need
    # to explicitly update the project_capsule status here

    redirect_to admin_project_satisfaction_survey_path(resource), notice: "Survey closed."
  end

  member_action :reopen_survey, method: :post do
    resource.update!({ closed_at: nil })

    # The project_satisfaction_survey_status_valid? method in ProjectCapsule
    # automatically checks the closed? status of the survey, so we don't need
    # to explicitly update the project_capsule status here

    redirect_to admin_project_satisfaction_survey_path(resource), notice: "Survey reopened!"
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.semantic_errors

      if f.object.project_satisfaction_survey_responses.any?
        h6 "This survey has already recorded #{f.object.project_satisfaction_survey_responses.count} responses, and its questions can no longer be changed."
        f.input :title
        f.input :description
      else
        f.input :title
        f.input :description

        f.has_many :project_satisfaction_survey_questions, heading: false, allow_destroy: true, new_record: 'Add a Question' do |a|
          a.input :prompt
        end
        f.has_many :project_satisfaction_survey_free_text_questions, heading: false, allow_destroy: true, new_record: 'Add a Free Text Question Prompt' do |a|
          a.input :prompt
        end

        # This captures the project_capsule_id from the URL parameter
        # It's hidden because it's pre-determined from the context and not user-editable
        f.input :project_capsule_id, as: :hidden
      end

      f.actions
    end
  end

  index download_links: false do
    column :title
    column :project do |resource|
      link_to resource.project_capsule.project_tracker.name, admin_project_tracker_path(resource.project_capsule.project_tracker)
    end

    column :respond do |resource|
      if resource.status == :open
        if resource.expected_responders.include?(current_admin_user)
          if ProjectSatisfactionSurveyResponder.find_by(project_satisfaction_survey: resource, admin_user: current_admin_user).present?
            span("✓ Responded", class: "pill yes")
          else
            link_to "Submit Response →", new_admin_project_satisfaction_survey_response_path(project_satisfaction_survey_id: resource.id)
          end
        else
          "You aren't required to respond to this survey"
        end
      else
        # Closed
        link_to "View Results →", admin_project_satisfaction_survey_path(resource)
      end
    end

    column :responses do |resource|
      "#{resource.project_satisfaction_survey_responses.count} responses (#{resource.expected_responders.count} expected)"
    end

    actions
  end

  show do
    render 'show', {
      project_satisfaction_survey_responder: ProjectSatisfactionSurveyResponder.find_by(project_satisfaction_survey: project_satisfaction_survey, admin_user: current_admin_user),
      expected_responder_status: resource.expected_responder_status,
      results: resource.results
    }
  end

  controller do
    def new
      build_resource

      # If we have a project_capsule_id, set up default questions
      if params[:project_capsule_id].present?
        project_capsule = ProjectCapsule.find(params[:project_capsule_id])

        # Set the project capsule and default title/description
        resource.project_capsule = project_capsule
        resource.title = "Project Satisfaction Survey: #{project_capsule.project_tracker.name}"
        resource.description = "Please provide your feedback on the #{project_capsule.project_tracker.name} project."

        # Add default questions
        ProjectSatisfactionSurvey::DEFAULT_RATING_QUESTIONS.each do |prompt|
          resource.project_satisfaction_survey_questions.build(
            prompt: prompt
          )
        end

        ProjectSatisfactionSurvey::DEFAULT_FREE_TEXT_QUESTIONS.each do |prompt|
          resource.project_satisfaction_survey_free_text_questions.build(
            prompt: prompt
          )
        end
      end

      flash[:notice] = "Please review the default questions (below) are relevant for your project."
      new!
    end

    def create
      super do |success, failure|
        if success.present?
          # Update the project capsule status when the survey is created
          resource.project_capsule.update!(project_satisfaction_survey_status: :project_satisfaction_survey_created)

          # Redirect to the show page with a success message
          redirect_to admin_project_satisfaction_survey_path(resource), notice: "Project satisfaction survey created!" and return
        end
      end
    end
  end
end