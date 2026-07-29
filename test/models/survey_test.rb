require "test_helper"

class SurveyTest < ActiveSupport::TestCase
  test "clone_from copies free-text questions into the correct association" do
    studio = Studio.create!(name: "S1", mini_name: "s1")
    survey = Survey.create!(title: "Original", description: "Original survey", opens_at: Date.today)
    survey.survey_questions.create!(prompt: "Q1")
    survey.survey_free_text_questions.create!(prompt: "FT1")
    survey.survey_studios.create!(studio: studio)

    clone = Survey.clone_from(survey)

    assert_equal 1, clone.survey_questions.count
    assert_equal 1, clone.survey_free_text_questions.count
    assert_equal 1, clone.survey_studios.count
    assert_equal "Cloned from: Original", clone.title
  end

  test "expected_responder_status includes elevated-service members as of reference date" do
    studio = Studio.create!(name: "Beta", mini_name: "beta")
    survey = Survey.create!(title: "B", description: "d", opens_at: Date.new(2026, 7, 1)) # ref -> Apr,May,Jun 2026
    survey.survey_studios.create!(studio: studio)

    au = AdminUser.create!(email: "elev@sanctuary.computer", password: "password12345", password_confirmation: "password12345")
    StudioMembership.create!(studio: studio, admin_user: au, started_at: Date.new(2026, 1, 1))
    fp = ForecastPerson.create!(forecast_id: 55_601, email: au.email, first_name: "E", last_name: "L", data: {})
    Contributor.create!(forecast_person: fp)

    # Qualify via the HOURS path (avoids the payout/ledger/qbo fixture chain):
    # one assignment spanning the 3 completed months, 8h/day => ~240h each month >= 120.
    project = ForecastProject.new(forecast_id: 77_601, name: "Client Work", client_id: 123_456)
    project.save!(validate: false)
    fa = ForecastAssignment.new(
      person_id: fp.forecast_id, project_id: project.forecast_id,
      allocation: 28_800, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30)
    )
    fa.save!(validate: false)

    assert_equal 3, survey.elevated_service_periods.size
    assert_includes survey.expected_responders, au
    assert survey.expected_responder_status[studio].key?(au)
  end
end
