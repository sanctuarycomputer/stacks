class ProjectCapsule < ApplicationRecord
  belongs_to :project_tracker

  scope :complete, -> {
    self
      .where.not(client_feedback_survey_status: nil)
      .where.not(internal_marketing_status: nil)
      .where.not(capsule_status: nil)
      .where.not(postpartum_notes: [nil, ""])
  }

  enum client_feedback_survey_status: {
    client_feedback_survey_received_and_shared_with_project_team: 0,
    no_response_from_client: 1,
    opt_out_of_sending_client_feedback_survey: 2
  }

  enum internal_marketing_status: {
    internal_marketing_scheduled_with_town_crier: 0,
    opt_out_out_of_internal_marketing: 1
  }

  enum capsule_status: {
    project_capsule_shared_with_garden3d_on_twist: 0,
    opt_out_of_sharing_project_capsule_with_garden3d: 1
  }

  def complete?
    client_feedback_survey_status.present? &&
    internal_marketing_status.present? &&
    capsule_status.present? &&
    postpartum_notes.present?
  end
end
