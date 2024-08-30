class CollectiveRole < ApplicationRecord
  has_many :collective_role_holder_periods, dependent: :delete_all
  accepts_nested_attributes_for :collective_role_holder_periods, allow_destroy: true
  has_many :collective_role_holders, through: :collective_role_holder_periods, source: :admin_user

  def current_collective_role_holders
    current_collective_role_holder_periods.map(&:admin_user)
  end

  def current_collective_role_holder_periods
    collective_role_holder_periods.select do |p|
      p.period_started_at <= Date.today && p.ended_at.nil?
    end
  end
end
