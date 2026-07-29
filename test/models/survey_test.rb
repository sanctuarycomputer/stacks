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
end
