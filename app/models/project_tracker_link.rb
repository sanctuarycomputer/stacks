class ProjectTrackerLink < ApplicationRecord
  belongs_to :project_tracker
  validates :name, presence: :true
  validates :url, format: URI::regexp(%w[http https])
  enum link_type: {
    other: 0,
    proposal: 1,
    project_wiki: 2,
    design_file: 3,
    staging_link: 4,
    production_link: 5,
    qa_document: 6,
    operator_manual: 5,
  }
end
