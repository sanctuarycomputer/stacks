class Finalization < ApplicationRecord
  belongs_to :review
  has_one :workspace, as: :reviewable
  accepts_nested_attributes_for :workspace

  before_create :build_workspace

  scope :finalized, -> {
    Finalization.all
  }

  private

  def build_workspace
    self.workspace = Workspace.new
  end
end
