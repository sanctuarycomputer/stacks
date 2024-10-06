class SurveyResponder < ApplicationRecord
  belongs_to :survey
  belongs_to :admin_user
end
