class DeelOffCyclePayment < ApplicationRecord
  self.primary_key = "deel_id"
  validates :deel_id, presence: true, uniqueness: true
  validates :deel_contract_id, presence: true

  belongs_to :deel_contract, class_name: "DeelContract", foreign_key: "deel_contract_id"
end