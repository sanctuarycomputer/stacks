require "test_helper"

class ProjectCapsuleTest < ActiveSupport::TestCase
  def make_tracker!(work_completed_at: 2.months.ago)
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:work_completed_at, work_completed_at)
    pt
  end

  # A capsule with every close-out obligation genuinely satisfied.
  def make_honest_capsule!(tracker: nil)
    tracker ||= make_tracker!
    capsule = ProjectCapsule.create!(
      project_tracker: tracker,
      client_feedback_survey_status: :client_feedback_survey_received_and_shared_with_project_team,
      client_feedback_survey_url: "https://www.notion.so/garden3d/response-abc123",
      internal_marketing_status: :case_study_scheduled_with_communications_team,
      capsule_status: :project_capsule_shared_with_garden3d_on_twist,
      project_satisfaction_survey_status: :internal_project_team_satisfaction_survey_created,
      client_satisfaction_status: :satisfied,
    )
    survey = ProjectSatisfactionSurvey.create!(
      project_capsule: capsule,
      title: "Survey",
      description: "Description",
    )
    survey.update!(closed_at: DateTime.now)
    capsule.reload
  end

  test "all_statuses_set? is true only when all four close-out enums are set" do
    capsule = ProjectCapsule.create!(project_tracker: make_tracker!)
    assert_not capsule.all_statuses_set?

    capsule.update!(
      client_feedback_survey_status: :no_response_from_client,
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
    )
    assert_not capsule.all_statuses_set?

    capsule.update!(project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey)
    assert capsule.all_statuses_set?
  end

  test "the all_statuses_set scope agrees with all_statuses_set? on the same records" do
    partial = ProjectCapsule.create!(
      project_tracker: make_tracker!,
      client_feedback_survey_status: :no_response_from_client,
    )
    full = make_honest_capsule!

    scoped_ids = ProjectCapsule.all_statuses_set.pluck(:id)
    assert_includes scoped_ids, full.id
    assert_not_includes scoped_ids, partial.id
    assert_equal full.all_statuses_set?, scoped_ids.include?(full.id)
    assert_equal partial.all_statuses_set?, scoped_ids.include?(partial.id)
  end

  test "substantively_complete? is true for a fully honest capsule" do
    assert make_honest_capsule!.substantively_complete?
  end

  test "substantively_complete? is false when client satisfaction is unset" do
    capsule = make_honest_capsule!
    capsule.update!(client_satisfaction_status: nil)
    assert_not capsule.substantively_complete?
  end

  test "substantively_complete? is false when the satisfaction survey is still open" do
    capsule = make_honest_capsule!
    capsule.project_satisfaction_survey.update!(closed_at: nil)
    assert_not capsule.reload.substantively_complete?
  end
end
