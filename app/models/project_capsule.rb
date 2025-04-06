class ProjectCapsule < ApplicationRecord
  belongs_to :project_tracker

  has_one :project_satisfaction_survey

  scope :complete, -> {
    self
      .where.not(client_feedback_survey_status: nil)
      .where.not(internal_marketing_status: nil)
      .where.not(capsule_status: nil)
      .where.not(project_satisfaction_survey_status: nil)
      .where.not(postpartum_notes: [nil, ""])
  }

  enum client_satisfaction_status: {
    satisfied: 0,
    dissatisfied: 1,
  }

  enum client_feedback_survey_status: {
    client_feedback_survey_received_and_shared_with_project_team: 0,
    no_response_from_client: 1,
    opt_out_of_sending_client_feedback_survey: 2
  }

  enum internal_marketing_status: {
    case_study_scheduled_with_communications_team: 0,
    opt_out_out_of_internal_marketing: 1
  }

  enum capsule_status: {
    project_capsule_shared_with_garden3d_on_twist: 0,
    opt_out_of_sharing_project_capsule_with_garden3d: 1
  }

  enum project_satisfaction_survey_status: {
    project_satisfaction_survey_completed: 0,
    project_satisfaction_survey_in_progress: 1,
    opt_out_of_project_satisfaction_survey: 2
  }

  def complete?
    client_feedback_survey_status.present? &&
    internal_marketing_status.present? &&
    capsule_status.present? &&
    project_satisfaction_survey_status.present? &&
    postpartum_notes.present? &&
    client_satisfaction_status.present? &&
    client_satisfaction_detail.present?
  end

  def ensure_project_satisfaction_survey_exists!
    return project_satisfaction_survey if project_satisfaction_survey.present?

    survey = ProjectSatisfactionSurvey.create!(
      project_capsule: self,
      title: "Project Satisfaction Survey: #{project_tracker.name}",
      description: "Please provide your feedback on the #{project_tracker.name} project.",
      opens_at: Date.today
    )

    # Add default questions
    survey.project_satisfaction_survey_questions.create!(
      prompt: "I felt the project was well organized"
    )

    survey.project_satisfaction_survey_questions.create!(
      prompt: "I had the resources I needed to complete my work on this project"
    )

    survey.project_satisfaction_survey_questions.create!(
      prompt: "Communication within the team was effective"
    )

    survey.project_satisfaction_survey_questions.create!(
      prompt: "The project goals were clear to me"
    )

    survey.project_satisfaction_survey_questions.create!(
      prompt: "I had enough time to complete my tasks"
    )

    # Add free text questions
    survey.project_satisfaction_survey_free_text_questions.create!(
      prompt: "What went well on this project?"
    )

    survey.project_satisfaction_survey_free_text_questions.create!(
      prompt: "What could be improved for future projects?"
    )

    survey.project_satisfaction_survey_free_text_questions.create!(
      prompt: "Any additional comments about the project?"
    )

    survey
  end
end
