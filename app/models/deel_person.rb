class DeelPerson < ApplicationRecord
  self.primary_key = "deel_id"
  validates :deel_id, presence: true, uniqueness: true
  has_many :deel_contracts, class_name: "DeelContract", foreign_key: "deel_person_id"

  def display_name
    data["full_name"]
  end
end