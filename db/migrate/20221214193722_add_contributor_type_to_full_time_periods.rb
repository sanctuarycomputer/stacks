class AddContributorTypeToFullTimePeriods < ActiveRecord::Migration[6.0]
  def change
    add_column :full_time_periods, :contributor_type, :integer, default: 0
    add_column :admin_users, :ignore, :boolean, default: false

    # Ensure every user has a FTP, and assume that if they don't they're variable.
    AdminUser.all.each do |a|
      if a.full_time_periods.empty?
        if ["core", "satellite"].include?(a.contributor_type)
          FullTimePeriod.create!({
            admin_user: a,
            started_at: Date.today,
            contributor_type: Enum::ContributorType::VARIABLE_HOURS
          })
        end
      end
    end

    # Mark bot admins as "ignore"
    AdminUser.all.each do |a|
      a.update!(ignore: true) if a.contributor_type == "bot"
    end

    # Update each FTP with the correct contributor_type for this period
    AdminUser.all.each do |a|
      a.full_time_periods.reload.map do |ftp|
        if a.contributor_type == "core"
          if ftp.multiplier == 0.8
            # 4 day worker
            next ftp.update!(contributor_type: Enum::ContributorType::FOUR_DAY)
          elsif ftp.multiplier == 1
            # 5 Day worker
            next ftp.update!(contributor_type: Enum::ContributorType::FIVE_DAY)
          elsif ftp.multiplier
            # ??? Give a "0" multiplier, probably should be variable_hours
            next ftp.update!({
              contributor_type: Enum::ContributorType::VARIABLE_HOURS,
              expected_utilization: 0
            })
          end
        end

        if a.contributor_type == "satellite"
          # Move to variable_hours
          next ftp.update!({
            contributor_type: Enum::ContributorType::VARIABLE_HOURS,
            expected_utilization: 0
          })
        end

        if a.contributor_type == "bot"
          # ??? Why does a bot have a FTP
          next ftp.destroy!
        end
      end
    end

    # Drop the old columns
    remove_column :admin_users, :contributor_type
    remove_column :full_time_periods, :multiplier
  end
end
