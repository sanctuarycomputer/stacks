class SurveyResponse < ApplicationRecord
  belongs_to :survey
  has_many :survey_question_responses
  accepts_nested_attributes_for :survey_question_responses, allow_destroy: true
end
