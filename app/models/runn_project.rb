class RunnProject < ApplicationRecord
  self.primary_key = "runn_id"
  has_one :project_tracker

  def self.candidates_for_association_with_project_tracker(project_tracker)
    associated = ProjectTracker.where.not(runn_project: nil).includes(:runn_project).map(&:runn_project)
    all = RunnProject.all
    unassociated = all.select{|rp| !associated.include?(rp)}
    [
      project_tracker.runn_project,
      *unassociated.select{|rp| rp.is_confirmed },
    ].compact.uniq
  end

  def link
    "https://app.runn.io/projects/#{runn_id}"
  end
end
