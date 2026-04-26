class OptixPlanTemplateLocation < ApplicationRecord
  belongs_to :optix_plan_template,
    foreign_key: :optix_plan_template_id,
    primary_key: :optix_id
  belongs_to :optix_location,
    foreign_key: :optix_location_id,
    primary_key: :optix_id

  validates :optix_plan_template_id,
    uniqueness: { scope: :optix_location_id }
end
