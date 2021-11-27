class Stacks::Dei
  class << self
    def make_rollup
      return if DeiRollup.this_month.any?

      data = [
        RacialBackground,
        CulturalBackground,
        GenderIdentity,
        Community,
      ].reduce({}) do |acc, klass|
        join_klass = "AdminUser#{klass.to_s}".constantize
        acc[klass.to_s.underscore] = klass.all.map do |o|
          getter = {}
          getter[klass.to_s.underscore] = o
          {
            id: o.id,
            name: o.name,
            skill_bands: (join_klass.preload(:admin_user).where(getter).map do |a|
              a.admin_user.skill_tree_level_without_salary
            end)
          }
        end
        acc
      end

      DeiRollup.create!(data: data)
    end
  end
end
