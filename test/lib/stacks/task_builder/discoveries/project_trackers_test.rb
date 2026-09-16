require 'test_helper'

class StacksTaskBuilderDiscoveriesProjectTrackersTest < ActiveSupport::TestCase
  def setup
    @admin = AdminUser.create!(email: "admin@sanctuary.computer", password: "passw0rd", roles: ["admin"])
    @lead = AdminUser.create!(email: "lead@sanctuary.computer", password: "passw0rd")
  end

  def discover
    Stacks::TaskBuilder::Discoveries::ProjectTrackers.new(admin_fallback: [@admin]).tasks
  end

  def make_wrapped_tracker!
    pt = ProjectTracker.new(name: "Client Project")
    pt.save!(validate: false)
    pt.update_column(:work_completed_at, 2.months.ago)
    ProjectLeadPeriod.create!(admin_user: @lead, project_tracker: pt, started_at: Date.today.beginning_of_month)
    AccountLeadPeriod.create!(admin_user: @lead, project_tracker: pt, started_at: Date.today.beginning_of_month)
    pt
  end

  # Otherwise complete, but opts out of the case study.
  def make_gated_capsule!(tracker)
    capsule = ProjectCapsule.create!(
      project_tracker: tracker,
      client_feedback_survey_status: :client_feedback_survey_received_and_shared_with_project_team,
      client_feedback_survey_url: "https://www.notion.so/garden3d/resp",
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
      capsule_status: :project_capsule_shared_with_garden3d_on_twist,
      project_satisfaction_survey_status: :opt_out_of_internal_project_team_satisfaction_survey,
      client_satisfaction_status: :satisfied,
    )
    capsule.reload
  end

  test "a gated capsule nags the admins for sign-off and the lead for completion" do
    pt = make_wrapped_tracker!
    capsule = make_gated_capsule!(pt)
    assert capsule.complete_but_for_admin_sign_off?, "fixture should be complete but for sign-off"

    tasks = discover.select { |t| t.subject.is_a?(ProjectTracker) && t.subject.id == pt.id }

    sign_off = tasks.find { |t| t.type == :project_capsule_needs_admin_sign_off }
    assert sign_off, "expected a project_capsule_needs_admin_sign_off task"
    assert_equal [@admin], sign_off.owners

    incomplete = tasks.find { |t| t.type == :project_capsule_incomplete }
    assert incomplete, "the lead should still be nagged to go do the real thing"
    assert_equal [@lead], incomplete.owners
  end

  test "a signed-off capsule yields neither task" do
    pt = make_wrapped_tracker!
    capsule = make_gated_capsule!(pt)
    capsule.update!(
      admin_signed_off_at: DateTime.now,
      admin_signed_off_by: @admin,
      admin_signed_off_selections: capsule.gated_selections,
    )

    tasks = discover.select { |t| t.subject.is_a?(ProjectTracker) && t.subject.id == pt.id }
    refute tasks.any? { |t| t.type == :project_capsule_needs_admin_sign_off }
    refute tasks.any? { |t| t.type == :project_capsule_incomplete }
  end

  test "a half-filled capsule nags the lead but not the admins" do
    pt = make_wrapped_tracker!
    ProjectCapsule.create!(
      project_tracker: pt,
      internal_marketing_status: :opt_out_out_of_publishing_a_case_study,
    )

    tasks = discover.select { |t| t.subject.is_a?(ProjectTracker) && t.subject.id == pt.id }
    assert tasks.any? { |t| t.type == :project_capsule_incomplete }
    refute tasks.any? { |t| t.type == :project_capsule_needs_admin_sign_off },
      "don't nag admins about a capsule the lead hasn't finished"
  end

  # Must use a capsule on the no_response path: gated_selections short-circuits
  # (`no_response_from_client? && no_response_grace_expired?`), so a capsule on any
  # other status never dereferences project_tracker and the assertion would be
  # vacuous.
  def make_no_response_capsule!(tracker)
    capsule = make_gated_capsule!(tracker)
    capsule.update!(client_feedback_survey_status: :no_response_from_client)
    tracker.update_column(:work_completed_at, 8.weeks.ago)
    capsule.update_column(:created_at, 8.weeks.ago)
    capsule.reload
  end

  test "the discovery does not fire a query per capsule for its project_tracker" do
    3.times { make_no_response_capsule!(make_wrapped_tracker!) }

    queries = 0
    counter = ->(_name, _start, _finish, _id, payload) do
      queries += 1 unless payload[:name].to_s =~ /SCHEMA|TRANSACTION/
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { discover }
    assert queries < 15, "expected a bounded query count, got #{queries} - check inverse_of / preloading"
  end
end
