class RunnProject < ApplicationRecord
  self.primary_key = "runn_id"

  def self.candidates_for_association_with_project_tracker(project_tracker)
    RunnProject.all
  end
end
