class Stacks::AdminUserSalaryWindowSyncer
  def initialize(admin_user)
    @admin_user = admin_user
  end

  def sync!
    Rails.logger.info("Syncing salary windows for #{@admin_user.display_name}...")

    result = target_dates.reduce({
      windows: [],
      last_window: nil
    }) do |acc, date|
      salary = salary_on_date(date)

      if acc[:last_window].present?
        next acc if acc[:last_window][:salary] == salary

        acc[:last_window][:end_date] = date - 1.day
      end

      new_window = {
        admin_user_id: @admin_user.id,
        salary: salary,
        start_date: date,
        end_date: nil,
        created_at: Date.today,
        updated_at: Date.today
      }

      acc[:windows] << new_window
      acc[:last_window] = new_window

      acc
    end

    ActiveRecord::Base.transaction do
      @admin_user.admin_user_salary_windows.delete_all
      AdminUserSalaryWindow.upsert_all(result[:windows])
    end
  end

  private

  def target_dates
    [
      @admin_user.start_date,
      *@admin_user.full_time_periods.map(&:started_at),
      *@admin_user.archived_reviews.map(&:archived_at),
      *Stacks::SkillLevelFinder.effective_dates
    ].uniq.sort.filter do |date|
      date >= @admin_user.start_date
    end
  end

  def salary_on_date(date)
    level = @admin_user.skill_tree_level_on_date(date)
    level[:salary] * weekly_utilization_rate(date)
  end

  def weekly_utilization_rate(date)
    ftp = @admin_user.full_time_periods.find do |ftp|
      ftp.include?(date)
    end

    if ftp.blank?
      return 1
    end

    ftp.four_day? ? 0.8 : 1
  end
end
