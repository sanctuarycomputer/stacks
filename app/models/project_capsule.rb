class ProjectCapsule < ApplicationRecord
  include BustsTaskCache

  belongs_to :project_tracker
  belongs_to :admin_signed_off_by, class_name: "AdminUser", optional: true

  has_one :project_satisfaction_survey

  NO_RESPONSE_GRACE_PERIOD = 4.weeks

  # Stable keys, not prose — these are persisted in admin_signed_off_selections,
  # so the wording can change without invalidating existing signatures.
  GATED_SELECTION_LABELS = {
    "client_feedback_survey"      => "Sending a client feedback survey",
    "client_feedback_no_response" => "Chasing an unresponsive client",
    "internal_marketing"          => "Publishing a case study",
    "capsule_sharing"             => "Sharing the capsule with garden3d",
    "satisfaction_survey"         => "The internal team satisfaction survey",
  }.freeze

  # The four close-out enums being filled in at all. NOT the same as #complete?,
  # which additionally requires client satisfaction, a closed satisfaction survey,
  # survey-URL proof, and admin sign-off on any opt-outs.
  scope :all_statuses_set, -> {
    self
      .where.not(client_feedback_survey_status: nil)
      .where.not(internal_marketing_status: nil)
      .where.not(capsule_status: nil)
      .where.not(project_satisfaction_survey_status: nil)
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
    opt_out_out_of_publishing_a_case_study: 1
  }

  enum capsule_status: {
    project_capsule_shared_with_garden3d_on_twist: 0,
    opt_out_of_sharing_project_capsule_with_garden3d: 1
  }

  enum project_satisfaction_survey_status: {
    internal_project_team_satisfaction_survey_created: 0,
    opt_out_of_internal_project_team_satisfaction_survey: 1
  }

  def all_statuses_set?
    client_feedback_survey_status.present? &&
    internal_marketing_status.present? &&
    capsule_status.present? &&
    project_satisfaction_survey_status.present?
  end

  # The close-out bar as it stood before bypass protections existed. Metrics that
  # feed compensation and OKRs read THIS, not #complete?, so that gating a capsule
  # can never move a number. See the spec, §6.
  def substantively_complete?
    all_statuses_set? &&
    client_satisfaction_status.present? &&
    project_satisfaction_survey_status_valid?
  end

  def complete?
    completeness_checks_pass? && admin_sign_off_satisfied?
  end

  # True when the lead has done everything they can and only an admin's signature
  # is outstanding. Drives the admin nag — we don't pester admins about a capsule
  # that is still half-filled.
  def complete_but_for_admin_sign_off?
    completeness_checks_pass? && !admin_sign_off_satisfied?
  end

  def gated_selections
    return [] if sign_off_exempt?
    [
      ("client_feedback_survey"      if opt_out_of_sending_client_feedback_survey?),
      ("client_feedback_no_response" if no_response_from_client? && no_response_grace_expired?),
      ("internal_marketing"          if opt_out_out_of_publishing_a_case_study?),
      ("capsule_sharing"             if opt_out_of_sharing_project_capsule_with_garden3d?),
      ("satisfaction_survey"         if opt_out_of_internal_project_team_satisfaction_survey?),
    ].compact
  end

  def gated_selection_labels
    gated_selections.map { |key| GATED_SELECTION_LABELS.fetch(key) }
  end

  def requires_admin_sign_off?
    gated_selections.any?
  end

  # Derived rather than invalidated by a callback, so update_column can't slip a
  # new opt-out under an old signature. Sign-off covers the selections an admin
  # actually saw: still valid if the lead has since REMOVED some (doing the honest
  # thing shouldn't force a re-signature), void the moment a selection appears
  # that nobody approved.
  def admin_sign_off_satisfied?
    return true unless requires_admin_sign_off?
    return false if admin_signed_off_at.blank?
    (gated_selections - admin_signed_off_selections.to_a).empty?
  end

  # Mirrors project_satisfaction_survey_status_valid?: claiming the client
  # responded requires linking their response.
  def client_feedback_survey_url_valid?
    return true if sign_off_exempt?
    return true unless client_feedback_survey_received_and_shared_with_project_team?
    client_feedback_survey_url.to_s.match?(%r{\Ahttps?://\S+\z})
  end

  def project_satisfaction_survey_status_valid?
    # Survey is valid if it's opted out
    return true if opt_out_of_internal_project_team_satisfaction_survey?

    # Survey is valid if it's created but also the survey is closed
    if internal_project_team_satisfaction_survey_created? && project_satisfaction_survey.present?
      return project_satisfaction_survey.closed?
    end

    # Otherwise, it's not valid (e.g., survey is open)
    false
  end

  private

  def completeness_checks_pass?
    substantively_complete? && client_feedback_survey_url_valid?
  end

  # Anchored on the EARLIEST wrap signal we have. work_completed_at alone is
  # resettable: uncomplete_work then complete_work rewrites it to DateTime.now
  # (app/admin/project_trackers.rb:303-312), buying another 4 weeks, repeatably.
  # project_capsules.created_at is immutable and is stamped at the first
  # complete_work, so the earlier of the two can't be pushed forward.
  def no_response_grace_anchor
    [project_tracker&.work_completed_at, created_at].compact.min
  end

  def no_response_grace_expired?
    anchor = no_response_grace_anchor
    anchor.present? && anchor < NO_RESPONSE_GRACE_PERIOD.ago
  end
end
