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

  # --- the gate (spec §4, §5) --------------------------------------------

  # An otherwise-complete capsule that opts out of exactly one obligation.
  def make_gated_capsule!(field, value, tracker: nil)
    capsule = make_honest_capsule!(tracker: tracker)
    capsule.update!(field => value)
    capsule.reload
  end

  test "each of the four opt-outs blocks completion until an admin signs off" do
    {
      client_feedback_survey_status: :opt_out_of_sending_client_feedback_survey,
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
    }.each do |field, value|
      capsule = make_gated_capsule!(field, value)
      assert capsule.requires_admin_sign_off?, "#{field} should require sign-off"
      assert_not capsule.complete?, "#{field} should block completion"
      assert capsule.complete_but_for_admin_sign_off?, "#{field} should be complete but for sign-off"

      capsule.update!(
        admin_signed_off_at: DateTime.now,
        admin_signed_off_selections: capsule.gated_selections,
      )
      assert capsule.complete?, "#{field} should complete once signed off"
      assert_not capsule.complete_but_for_admin_sign_off?
    end
  end

  test "an honest capsule completes with no sign-off at all" do
    capsule = make_honest_capsule!
    assert_not capsule.requires_admin_sign_off?
    assert capsule.complete?
    assert_nil capsule.admin_signed_off_at
  end

  test "sign-off survives the lead REMOVING an approved opt-out" do
    capsule = make_honest_capsule!
    capsule.update!(
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
    )
    assert_equal %w[internal_marketing capsule_sharing].sort, capsule.gated_selections.sort
    capsule.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_selections: capsule.gated_selections,
    )
    assert capsule.complete?

    # Lead goes and does the real thing for one of them.
    capsule.update!(capsule_status: :project_capsule_shared_with_garden3d_on_twist)
    assert capsule.reload.complete?, "removing an approved opt-out must not void the signature"
  end

  test "sign-off is void when the lead SWAPS in an unapproved opt-out" do
    capsule = make_gated_capsule!(:internal_marketing_status, :opt_out_out_of_publishing_a_case_study)
    capsule.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_selections: capsule.gated_selections,
    )
    assert capsule.complete?

    capsule.update!(
      internal_marketing_status: :case_study_scheduled_with_communications_team,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
    )
    assert_not capsule.reload.complete?, "an unapproved selection must re-block the capsule"
  end

  test "update_column cannot preserve a stale signature" do
    capsule = make_gated_capsule!(:project_satisfaction_survey_status, :opt_out_of_internal_project_team_satisfaction_survey)
    capsule.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_selections: capsule.gated_selections,
    )
    assert capsule.complete?

    # Callback-free write, as ProjectSatisfactionSurvey#reset_project_capsule_survey_flow does.
    capsule.update_column(:capsule_status, ProjectCapsule.capsule_statuses[:opt_out_of_sharing_project_capsule_with_garden3d])
    assert_not capsule.reload.complete?, "a derived gate must not be bypassable via update_column"
  end

  test "creating the internal satisfaction survey does not void an unrelated approval" do
    # Gated on TWO things; the admin approves both. Then the lead does the honest
    # thing for one of them, which is the exact update! at
    # app/admin/project_satisfaction_surveys.rb:161. A naive callback-based
    # invalidation would revoke the signature here and force a re-signature.
    capsule = make_honest_capsule!
    capsule.update!(
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
    )
    assert_equal %w[internal_marketing satisfaction_survey].sort, capsule.gated_selections.sort
    capsule.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_selections: capsule.gated_selections,
    )
    assert capsule.complete?

    capsule.update!(project_satisfaction_survey_status: :internal_project_team_satisfaction_survey_created)
    assert capsule.reload.complete?, "honest work must not force a re-signature"
  end

  test "no_response_from_client is free inside the grace period and gated after it" do
    # The grace anchor is capsule created_at, not tracker.work_completed_at (see
    # no_response_grace_anchor) — pin created_at directly to simulate elapsed time.
    inside = make_gated_capsule!(
      :client_feedback_survey_status, :no_response_from_client,
      tracker: make_tracker!(work_completed_at: 3.weeks.ago),
    )
    inside.update_column(:created_at, 3.weeks.ago)
    assert_not inside.reload.requires_admin_sign_off?
    assert inside.complete?

    outside = make_gated_capsule!(
      :client_feedback_survey_status, :no_response_from_client,
      tracker: make_tracker!(work_completed_at: 5.weeks.ago),
    )
    outside.update_column(:created_at, 5.weeks.ago)
    assert_equal ["client_feedback_no_response"], outside.reload.gated_selections
    assert_not outside.complete?
  end

  test "the grace clock cannot be reset by uncompleting and recompleting the work" do
    tracker = make_tracker!(work_completed_at: 5.weeks.ago)
    capsule = make_gated_capsule!(:client_feedback_survey_status, :no_response_from_client, tracker: tracker)
    capsule.update_column(:created_at, 5.weeks.ago)
    assert_not capsule.reload.complete?

    # What app/admin/project_trackers.rb:303-312 does on two clicks.
    tracker.update_column(:work_completed_at, nil)
    tracker.update_column(:work_completed_at, DateTime.now)

    assert_not capsule.reload.complete?,
      "re-wrapping must not buy another grace period"
  end

  test "the grace clock ignores work_completed_at entirely" do
    tracker = make_tracker!(work_completed_at: nil)
    capsule = make_gated_capsule!(:client_feedback_survey_status, :no_response_from_client, tracker: tracker)
    capsule.update_column(:created_at, 5.weeks.ago)
    assert_not capsule.reload.complete?
  end

  test "claiming the client responded requires a well-formed survey url" do
    capsule = make_honest_capsule!
    assert capsule.complete?

    capsule.update!(client_feedback_survey_url: nil)
    assert_not capsule.reload.complete?, "a blank url is not proof"

    capsule.update!(client_feedback_survey_url: "n/a")
    assert_not capsule.reload.complete?, "'n/a' is not proof"

    capsule.update!(client_feedback_survey_url: "https://www.notion.so/garden3d/resp")
    assert capsule.reload.complete?

    capsule.update!(client_feedback_survey_url: "  https://www.notion.so/garden3d/resp  ")
    assert capsule.reload.complete?, "a pasted url with stray whitespace is still proof"

    capsule.update!(client_feedback_survey_url: "https://x.com\nn/a")
    assert_not capsule.reload.complete?, "a multi-line value must not pass"
  end

  test "sign_off_exempt bypasses both the sign-off gate and the url proof" do
    capsule = make_gated_capsule!(:internal_marketing_status, :opt_out_out_of_publishing_a_case_study)
    capsule.update!(sign_off_exempt: true, client_feedback_survey_url: nil)

    assert_empty capsule.gated_selections
    assert_not capsule.requires_admin_sign_off?
    assert capsule.complete?
  end

  test "complete_but_for_admin_sign_off? is false while other requirements are unmet" do
    capsule = make_gated_capsule!(:internal_marketing_status, :opt_out_out_of_publishing_a_case_study)
    capsule.update!(client_satisfaction_status: nil)

    assert capsule.requires_admin_sign_off?
    assert_not capsule.complete?
    assert_not capsule.complete_but_for_admin_sign_off?,
      "don't nag admins about a capsule the lead hasn't finished"
  end

  test "gated_selection_labels renders prose for every key" do
    capsule = make_honest_capsule!(tracker: make_tracker!(work_completed_at: 8.weeks.ago))
    capsule.update!(
      client_feedback_survey_status: :no_response_from_client,
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :opt_out_of_sharing_project_capsule_with_garden3d,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
    )
    capsule.update_column(:created_at, 8.weeks.ago)
    capsule.reload

    # Four opt-outs + the expired no-response hatch = four keys here, since the
    # client feedback slot can only be in ONE state at a time.
    assert_equal 4, capsule.gated_selections.length
    assert_equal capsule.gated_selections.length, capsule.gated_selection_labels.length
    capsule.gated_selections.each { |k| assert_includes ProjectCapsule::GATED_SELECTION_LABELS.keys, k }
    assert_includes capsule.gated_selection_labels, "Chasing an unresponsive client"
    assert_includes capsule.gated_selection_labels, "Publishing a case study"
  end

  test "the grace clock is anchored on the capsule row and cannot be moved by re-wrapping" do
    tracker = make_tracker!(work_completed_at: 6.months.ago)
    capsule = make_gated_capsule!(:client_feedback_survey_status, :no_response_from_client, tracker: tracker)
    capsule.update_column(:created_at, 8.weeks.ago)
    assert_not capsule.reload.complete?, "8 weeks past creation is well outside the 4-week grace"

    # What two clicks on the tracker page do (app/admin/project_trackers.rb:303-312).
    tracker.update_column(:work_completed_at, nil)
    tracker.update_column(:work_completed_at, DateTime.now)
    assert_not capsule.reload.complete?, "re-wrapping must not hand back grace"

    # And nulling it entirely must not either.
    tracker.update_column(:work_completed_at, nil)
    assert_not capsule.reload.complete?, "an absent wrap date must not hand back grace"
  end

  test "mark_work_completed! stamps the capsule so created_at tracks the first wrap" do
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    assert_nil pt.project_capsule

    pt.mark_work_completed!(at: 6.months.ago)
    assert pt.reload.project_capsule.present?,
      "a wrap set through mark_work_completed! must create the capsule, or created_at stops tracking the wrap"
  end

  test "junk in admin_signed_off_selections does not act as a blanket signature" do
    capsule = make_gated_capsule!(:internal_marketing_status, :opt_out_out_of_publishing_a_case_study)
    capsule.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_selections: ["not_a_real_key", "internal_marketing"],
    )
    assert capsule.complete?, "a real approved key still counts"

    capsule.update!(admin_signed_off_selections: ["not_a_real_key"])
    assert_not capsule.reload.complete?, "junk keys alone must not satisfy the gate"
  end
end
