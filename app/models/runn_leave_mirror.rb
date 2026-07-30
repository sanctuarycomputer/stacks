class RunnLeaveMirror < ApplicationRecord
  validates :runn_person_id, :start_date, :end_date, :refreshed_at, presence: true
end
