class OptixUser < ApplicationRecord
  self.primary_key = "optix_id"

  belongs_to :optix_organization

  has_many :optix_account_plans,
    foreign_key: :access_usage_user_optix_id,
    primary_key: :optix_id

  scope :with_active_plan, -> {
    joins(:optix_account_plans).where(
      optix_account_plans: { status: %w[ACTIVE IN_TRIAL] }
    ).distinct
  }

  # The user has at least one ACTIVE or IN_TRIAL plan right now.
  def active_member?
    optix_account_plans.where(status: %w[ACTIVE IN_TRIAL]).exists?
  end

  # The single "current" plan for this user — the most recently started ACTIVE
  # or IN_TRIAL plan. Useful for displaying tier on a member roster.
  def current_plan
    optix_account_plans
      .where(status: %w[ACTIVE IN_TRIAL])
      .order(start_timestamp: :desc)
      .first
  end

  # Convenience for displaying the tier name without a separate join.
  def current_tier_name
    current_plan&.optix_plan_template&.name
  end
end
