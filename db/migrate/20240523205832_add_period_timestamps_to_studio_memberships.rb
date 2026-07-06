class AddPeriodTimestampsToStudioMemberships < ActiveRecord::Migration[6.0]
  def change
    add_column :studio_memberships, :started_at, :date
    add_column :studio_memberships, :ended_at, :date

    AdminUser.all.each do |a|
      sms = a.studio_memberships.sort_by{|sm| sm.created_at}

      sms.each do |sm|
        sm.started_at = sm.created_at
        sm.save(validate: false)
        sm.reload
      end

      sms.each_with_index do |sm, index|
        next_sm = sms[index + 1]
        if next_sm
          sm.update!(ended_at: (next_sm.created_at - 1.day))
        end
      end
    end

    change_column_null :studio_memberships, :started_at, false
  end
end
