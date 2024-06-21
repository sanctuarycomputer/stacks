class ProjectTrackerRunnProject < ApplicationRecord
  belongs_to :project_tracker
  #belongs_to :runn_project, primary_key: :runn_id
  belongs_to :runn_project, class_name: "RunnProject", foreign_key: "runn_project_id", primary_key: "runn_id"

  validates :runn_project, uniqueness: true
end
