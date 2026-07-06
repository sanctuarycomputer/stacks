class OptixPlanTemplate < ApplicationRecord
  self.primary_key = "optix_id"

  belongs_to :optix_organization

  has_many :optix_plan_template_locations,
    foreign_key: :optix_plan_template_id,
    primary_key: :optix_id,
    dependent: :destroy
  has_many :optix_locations,
    through: :optix_plan_template_locations

  has_many :optix_account_plans,
    foreign_key: :optix_plan_template_id,
    primary_key: :optix_id
end
