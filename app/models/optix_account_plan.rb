class OptixAccountPlan < ApplicationRecord
  self.primary_key = "optix_id"

  belongs_to :optix_organization
  belongs_to :optix_plan_template,
    foreign_key: :optix_plan_template_id,
    primary_key: :optix_id,
    optional: true
  belongs_to :access_usage_user,
    class_name: "OptixUser",
    foreign_key: :access_usage_user_optix_id,
    primary_key: :optix_id,
    optional: true

  has_many :optix_locations, through: :optix_plan_template

  scope :active,    -> { where(status: "ACTIVE") }
  scope :in_trial,  -> { where(status: "IN_TRIAL") }
  scope :paying,    -> { where(status: %w[ACTIVE IN_TRIAL]) }

  # Plans active at a specific moment in time, derived purely from timestamps.
  # Useful for historical "who was active last month" queries that don't
  # depend on Optix's current `status` field (which can change after the fact).
  scope :active_at, ->(time) {
    t = time.to_i
    where("start_timestamp <= ?", t)
      .where("end_timestamp IS NULL OR end_timestamp > ?", t)
      .where("canceled_timestamp IS NULL OR canceled_timestamp > ?", t)
  }
end
