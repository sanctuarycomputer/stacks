class Stacks::Dei
  class << self
    def make_rollup(force = false)
      return if DeiRollup.this_month.any? unless force
      DeiRollup.this_month.delete_all

      admin_users_with_dei_response =
        AdminUser.active.select{|a| !a.should_nag_for_dei_data?}

      data = [
        RacialBackground,
        CulturalBackground,
        GenderIdentity,
        Community,
      ].reduce({
        meta: {
          total: admin_users_with_dei_response.count
        }
      }) do |acc, klass|
        join_klass = "AdminUser#{klass.to_s}".constantize
        acc[klass.to_s.underscore] = klass.all.map do |o|
          getter = {}
          getter[klass.to_s.underscore] = o
          joins = join_klass.preload(:admin_user).where(getter)
          # Filter joins for Admin Users who haven't finished their DEI response
          joins = joins.select{|j| admin_users_with_dei_response.include?(j.admin_user)}
          {
            id: o.id,
            name: o.name,
            skill_bands: (joins.map do |a|
              a.admin_user.active? ? a.admin_user.skill_tree_level_without_salary : nil
            end).compact,
            admin_user_ids: (joins.map do |a|
              a.admin_user.active? ? a.admin_user.id : nil
            end).compact
          }
        end
        acc
      end

      DeiRollup.create!(data: data)
    end
  end
end
