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
    project_satisfaction_survey_created: 0,
    opt_out_of_project_satisfaction_survey: 1
  }

  def complete?
    client_feedback_survey_status.present? &&
    internal_marketing_status.present? &&
    capsule_status.present? &&
    project_satisfaction_survey_status.present? &&
    project_satisfaction_survey_status_valid? &&
    postpartum_notes.present? &&
    client_satisfaction_status.present? &&
    client_satisfaction_detail.present?
  end

  def project_satisfaction_survey_status_valid?
    # Survey is valid if it's opted out
    return true if opt_out_of_project_satisfaction_survey?

    # Survey is valid if it's created but also the survey is closed
    if project_satisfaction_survey_created? && project_satisfaction_survey.present?
      return project_satisfaction_survey.closed?
    end

    # Otherwise, it's not valid (e.g., survey is open)
    false
  end
end
