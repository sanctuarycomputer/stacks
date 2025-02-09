class ProjectTrackerZenhubWorkspace < ApplicationRecord
  belongs_to :project_tracker
  belongs_to :zenhub_workspace
end
