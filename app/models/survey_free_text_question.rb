class SurveyFreeTextQuestion < ApplicationRecord
  belongs_to :survey

  def name
    prompt
  end
end
