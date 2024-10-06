class SurveyQuestionResponse < ApplicationRecord

  belongs_to :survey_question
  belongs_to :survey_response

  enum sentiment: {
    strongly_disagree: 1, # 0
    disagree: 2, # 1.25
    neutral: 3, # 2.5
    agree: 4, # 3.75
    strongly_agree: 5, # 5
  }

  validates :sentiment, inclusion: { in: SurveyQuestionResponse.sentiments.keys }

  # Dumb function I'm tired
  def self.sentiment_to_score(sentiment_string)
    case sentiment_string
    when "strongly_agree"
      5
    when "agree"
      3.75
    when "neutral"
      2.5
    when "disagree"
      1.25
    else
      0
    end
  end
end
