class SurveyResponder < ApplicationRecord
  include BustsTaskCache

  belongs_to :survey
  belongs_to :admin_user
end
