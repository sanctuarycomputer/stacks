ActiveAdmin.register ProjectSatisfactionSurvey do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :create, :edit, :update, :delete
  menu false

  scope :open, default: true
  scope :closed
  scope :draft
  scope :all

  permit_params :title,
    :description,
    :opens_at,
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

  action_item :duplicate_survey, only: [:show, :edit], if: proc { current_admin_user.is_admin? } do
    link_to "Duplicate", clone_survey_admin_project_satisfaction_survey_path(resource), method: :post
  end

  action_item :close_survey, only: [:show, :edit], if: proc { current_admin_user.is_admin? } do
    if resource.status == :open
      link_to "Close Survey", close_survey_admin_project_satisfaction_survey_path(resource), method: :post
    end
  end

  action_item :reopen_survey, only: [:show, :edit], if: proc { current_admin_user.is_admin? } do
    if resource.status == :closed
      link_to "Reopen Survey", reopen_survey_admin_project_satisfaction_survey_path(resource), method: :post
    end
  end

  member_action :clone_survey, method: :post do
    new_survey = ProjectSatisfactionSurvey.clone_from(resource)
    redirect_to edit_admin_project_satisfaction_survey_path(new_survey), notice: "Success!"
  end

  member_action :close_survey, method: :post do
    resource.update!({ closed_at: DateTime.now })

    # Update project capsule status if all expected responses have been submitted
    if resource.project_satisfaction_survey_responses.count >= resource.expected_responders.count
      resource.project_capsule.update!(project_satisfaction_survey_status: :project_satisfaction_survey_completed)
    end

    redirect_to admin_project_satisfaction_survey_path(resource), notice: "Survey closed."
  end

  member_action :reopen_survey, method: :post do
    resource.update!({ closed_at: nil })

    # Update project capsule status to in progress
    resource.project_capsule.update!(project_satisfaction_survey_status: :project_satisfaction_survey_in_progress)

    redirect_to admin_project_satisfaction_survey_path(resource), notice: "Survey reopened!"
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.semantic_errors

      if f.object.project_satisfaction_survey_responses.any?
        h6 "This survey has already recorded #{f.object.project_satisfaction_survey_responses.count} responses, and its questions can no longer be changed."
        f.input :title
        f.input :description
        f.input :opens_at,
          hint: "This is the date project members will be able to start recording their responses."
      else
        f.input :title
        f.input :description
        f.input :opens_at,
          hint: "This is the date project members will be able to start recording their responses."

        f.has_many :project_satisfaction_survey_questions, heading: false, allow_destroy: true, new_record: 'Add a Question' do |a|
          a.input :prompt
        end
        f.has_many :project_satisfaction_survey_free_text_questions, heading: false, allow_destroy: true, new_record: 'Add a Free Text Question Prompt' do |a|
          a.input :prompt
        end
      end

      f.actions if current_admin_user.is_admin?
    end
  end

  index download_links: false do
    column :title
    column :project do |resource|
      link_to resource.project_capsule.project_tracker.name, admin_project_tracker_path(resource.project_capsule.project_tracker)
    end

    column :respond do |resource|
      if resource.status == :draft
        # No options
      elsif resource.status == :open
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
end