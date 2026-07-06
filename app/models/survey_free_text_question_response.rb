class SurveyFreeTextQuestionResponse < ApplicationRecord
  belongs_to :survey_free_text_question
  belongs_to :survey_response
end
