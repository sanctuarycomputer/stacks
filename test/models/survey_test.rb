require "test_helper"

class SurveyTest < ActiveSupport::TestCase
  test "reference_date is capped at today for surveys opening in the future" do
    survey = Survey.create!(title: "Future", description: "d", opens_at: Date.today + 4.weeks)
    assert_equal Date.today, survey.reference_date
    # elevated-service window = the 3 completed months before THIS month (not shifted forward)
    assert_equal 3, survey.elevated_service_periods.size
    assert_equal (Date.today.beginning_of_month - 3.months),
                 survey.elevated_service_periods.first.starts_at
    assert_equal (Date.today.beginning_of_month - 1.month),
                 survey.elevated_service_periods.last.starts_at
  end

  test "reference_date uses opens_at for past (closed) surveys" do
    survey = Survey.create!(title: "Past", description: "d", opens_at: Date.new(2024, 6, 1))
    assert_equal Date.new(2024, 6, 1), survey.reference_date
  end

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

  test "responder_status adds actual respondents not in the expected set under Other" do
    studio = Studio.create!(name: "Gamma", mini_name: "gamma")
    survey = Survey.create!(title: "G", description: "d", opens_at: Date.new(2026, 7, 1))
    survey.survey_studios.create!(studio: studio)

    outsider = AdminUser.create!(email: "outsider@sanctuary.computer", password: "password12345", password_confirmation: "password12345")
    SurveyResponder.create!(survey: survey, admin_user: outsider)

    status = survey.responder_status
    other_key = status.keys.find { |k| k == Survey::OTHER_RESPONDENTS }
    assert other_key, "expected an Other respondents group"
    assert status[other_key].key?(outsider)
    assert_not survey.expected_responders.include?(outsider) # not inflated
  end

  test "expected_responder? matches expected_responders membership without inflating" do
    studio = Studio.create!(name: "Delta", mini_name: "delta")
    survey = Survey.create!(title: "D", description: "d", opens_at: Date.new(2026, 7, 1))
    survey.survey_studios.create!(studio: studio)

    # elevated member (hours path), studio member
    au = AdminUser.create!(email: "er@sanctuary.computer", password: "password12345", password_confirmation: "password12345")
    StudioMembership.create!(studio: studio, admin_user: au, started_at: Date.new(2026, 1, 1))
    fp = ForecastPerson.create!(forecast_id: 78_101, email: au.email, first_name: "E", last_name: "R", data: {})
    Contributor.create!(forecast_person: fp)
    project = ForecastProject.new(forecast_id: 78_111, name: "Client Work", client_id: 123_456)
    project.save!(validate: false)
    ForecastAssignment.new(person_id: fp.forecast_id, project_id: project.forecast_id,
      allocation: 28_800, start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30)).save!(validate: false)

    # a non-member outsider
    outsider = AdminUser.create!(email: "out@sanctuary.computer", password: "password12345", password_confirmation: "password12345")

    assert survey.expected_responder?(au),        "elevated studio member should be expected"
    assert_not survey.expected_responder?(outsider), "non-member should not be expected"
    # parity with the full set
    assert_equal survey.expected_responders.include?(au), survey.expected_responder?(au)
    assert_equal survey.expected_responders.include?(outsider), survey.expected_responder?(outsider)
  end
end
