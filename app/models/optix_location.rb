class OptixLocation < ApplicationRecord
  self.primary_key = "optix_id"

  belongs_to :optix_organization

  has_many :optix_plan_template_locations,
    foreign_key: :optix_location_id,
    primary_key: :optix_id,
    dependent: :destroy
  has_many :optix_plan_templates,
    through: :optix_plan_template_locations
end
