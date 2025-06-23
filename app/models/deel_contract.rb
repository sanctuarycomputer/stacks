class DeelContract < ApplicationRecord
  self.primary_key = "deel_id"
  validates :deel_id, presence: true, uniqueness: true
  validates :deel_person_id, presence: true

  belongs_to :deel_person, class_name: "DeelPerson", foreign_key: "deel_person_id"
end