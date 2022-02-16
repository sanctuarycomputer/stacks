class Stacks::Dei
  class << self
    def make_rollup(force = false)
      return if DeiRollup.this_month.any? unless force

      data = [
        RacialBackground,
        CulturalBackground,
        GenderIdentity,
        Community,
      ].reduce({
        meta: { total: AdminUser.active.count }
      }) do |acc, klass|
        join_klass = "AdminUser#{klass.to_s}".constantize
        acc[klass.to_s.underscore] = klass.all.map do |o|
          getter = {}
          getter[klass.to_s.underscore] = o
          joins = join_klass.preload(:admin_user).where(getter)
          {
            id: o.id,
            name: o.name,
            skill_bands: (joins.map do |a|
              a.admin_user.archived_at.present? ? nil : a.admin_user.skill_tree_level_without_salary
            end).compact,
            admin_user_ids: (joins.map do |a|
              a.admin_user.archived_at.present? ? nil : a.admin_user.id
            end).compact
          }
        end
        acc
      end

      DeiRollup.create!(data: data)
    end
  end
end
