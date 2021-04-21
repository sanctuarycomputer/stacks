class Finalization < ApplicationRecord
  acts_as_paranoid

  belongs_to :review
  has_one :workspace, as: :reviewable, dependent: :destroy
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
