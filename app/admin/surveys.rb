ActiveAdmin.register Survey do
  config.filters = false
  config.paginate = false
  actions :index, :new, :show, :create, :edit, :update, :delete
  menu label: "Studio Surveys", parent: "All Surveys", priority: 1

  scope :open, default: true
  scope :closed
  scope :draft
  scope :all

  permit_params :title,
    :description,
    :opens_at,
    survey_questions_attributes: [
      :id,
      :survey_id,
      :prompt,
      :_destroy,
      :_edit
    ],
    survey_free_text_questions_attributes: [
      :id,
      :survey_id,
      :prompt,
      :_destroy,
      :_edit
    ],
    survey_studios_attributes: [
      :id,
      :survey_id,
      :studio_id,
      :_destroy,
      :_edit
    ]

  action_item :duplicate_survey, only: [:show, :edit], if: proc { current_admin_user.is_admin? } do
    link_to "Duplicate", clone_survey_admin_survey_path(resource), method: :post
  end

  action_item :close_survey, only: [:show, :edit], if: proc { current_admin_user.is_admin? } do
    if resource.status == :open
      link_to "Close Survey", close_survey_admin_survey_path(resource), method: :post
    end
  end

  action_item :reopen_survey, only: [:show, :edit], if: proc { current_admin_user.is_admin? } do
    if resource.status == :closed
      link_to "Reopen Survey", reopen_survey_admin_survey_path(resource), method: :post
    end
  end

  member_action :clone_survey, method: :post do
    new_survey = Survey.clone_from(resource)
    redirect_to edit_admin_survey_path(new_survey), notice: "Success!"
  end

  member_action :close_survey, method: :post do
    resource.update!({ closed_at: DateTime.now })
    redirect_to admin_survey_path(resource), notice: "Survey closed."
  end

  member_action :reopen_survey, method: :post do
    resource.update!({ closed_at: nil })
    redirect_to admin_survey_path(resource), notice: "Survey reopened!"
  end

  form do |f|
    f.inputs(class: "admin_inputs") do
      f.semantic_errors

      if f.object.survey_responses.any?
        h6 "This survey has already recorded #{f.object.survey_responses.count} responses, and it's questions or studio recipients can no longer be changed."
        f.input :title, disabled: true
        f.input :description, disabled: true
        f.input :opens_at, disabled: true,
          hint: "This is the date members in the studios selected will be able to start recording their responses."
      else
        f.input :title
        f.input :description
        f.input :opens_at,
          hint: "This is the date members in the studios selected will be able to start recording their responses."

        f.has_many :survey_questions, heading: false, allow_destroy: true, new_record: 'Add a Question' do |a|
          a.input :prompt
        end
        f.has_many :survey_free_text_questions, heading: false, allow_destroy: true, new_record: 'Add a Free Text Question Prompt' do |a|
          a.input :prompt
        end
        f.has_many :survey_studios, heading: false, allow_destroy: true, new_record: 'Add a Studio' do |a|
          a.input :studio
        end
      end

      f.actions if current_admin_user.is_admin?
    end
  end

  index download_links: false do
    column :title
    column :studios

    column :respond do |resource|
      if resource.status == :draft
        # No options
      elsif resource.status == :open
        if resource.expected_responders.include?(current_admin_user)
          if SurveyResponder.find_by(survey: resource, admin_user: current_admin_user).present?
            span("✓ Responded", class: "pill yes")
          else
            link_to "Submit Response →", new_admin_survey_response_path(survey_id: resource.id)
          end
        else
          "You aren't required to respond to this survey"
        end
      else
        # Closed
        link_to "View Results →", admin_survey_path(resource)
      end
    end

    column :responses do |resource|
      "#{resource.survey_responses.count} responses (#{resource.expected_responders.count} expected)"
    end

    actions
  end

  show do
    render 'show', {
      survey_responder: SurveyResponder.find_by(survey: survey, admin_user: current_admin_user),
      expected_responder_status: resource.expected_responder_status,
      results: resource.results
    }
  end
end
