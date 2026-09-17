require 'test_helper'

class AdminProjectCapsuleSignOffTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def make_admin!
    AdminUser.create!(email: "boss#{SecureRandom.hex(4)}@sanctuary.computer",
                      password: 'password12345', password_confirmation: 'password12345',
                      roles: ['admin'])
  end

  def make_lead!(tracker)
    user = AdminUser.create!(email: "lead#{SecureRandom.hex(4)}@sanctuary.computer",
                             password: 'password12345', password_confirmation: 'password12345')
    ProjectLeadPeriod.create!(admin_user: user, project_tracker: tracker,
                              started_at: Date.today.beginning_of_month)
    user
  end

  def make_gated_capsule!
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:work_completed_at, 2.months.ago)
    ProjectCapsule.create!(
      project_tracker: pt,
      client_feedback_survey_status: :opt_out_of_sending_client_feedback_survey,
      internal_marketing_status: :case_study_scheduled_with_communications_team,
      capsule_status: :project_capsule_shared_with_garden3d_on_twist,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
      client_satisfaction_status: :satisfied,
    )
  end

  test "the edit page renders the sign-off warning panel for a gated capsule" do
    capsule = make_gated_capsule!
    sign_in make_admin!

    get edit_admin_project_capsule_path(capsule)
    assert_response :success
    assert_includes response.body, "needs admin sign-off"
    assert_includes response.body, "Sending a client feedback survey"
    assert_includes response.body, "The internal team satisfaction survey"
  end

  test "an admin can sign off, and the capsule completes" do
    capsule = make_gated_capsule!
    sign_in make_admin!

    assert_not capsule.complete?
    post sign_off_admin_project_capsule_path(capsule)
    assert_response :redirect

    capsule.reload
    assert capsule.complete?
    assert capsule.admin_signed_off_at.present?
    assert_equal capsule.gated_selections.sort, capsule.admin_signed_off_selections.sort
  end

  test "a project lead cannot sign off their own capsule" do
    capsule = make_gated_capsule!
    sign_in make_lead!(capsule.project_tracker)

    # Positive control: prove the session is live and the lead can actually
    # reach the page, so the denial below isn't just `sign_in` silently
    # failing.
    get edit_admin_project_capsule_path(capsule)
    assert_response :success

    post sign_off_admin_project_capsule_path(capsule)
    assert_response :redirect
    assert_not capsule.reload.complete?, "a lead must not be able to approve their own bypass"
    assert_nil capsule.admin_signed_off_at
  end

  test "the tracker page renders the sign-off banner for a gated capsule" do
    capsule = make_gated_capsule!
    sign_in make_admin!

    get admin_project_tracker_path(capsule.project_tracker)
    assert_response :success
    assert_includes response.body, "An admin needs to approve"
  end

  test "the needs_capsule_sign_off admin scope lists a gated tracker" do
    capsule = make_gated_capsule!
    sign_in make_admin!

    get admin_project_trackers_path(scope: "needs_capsule_sign_off")
    assert_response :success
    assert_includes response.body, capsule.project_tracker.name
  end

  test "an admin can revoke a sign-off" do
    capsule = make_gated_capsule!
    sign_in make_admin!
    post sign_off_admin_project_capsule_path(capsule)
    assert capsule.reload.complete?

    post revoke_sign_off_admin_project_capsule_path(capsule)
    capsule.reload
    assert_not capsule.complete?
    assert_nil capsule.admin_signed_off_at
    assert_empty capsule.admin_signed_off_selections
  end
end
