class AdminUser < ApplicationRecord
  scope :active, -> {
          AdminUser.where(archived_at: nil)
        }
  scope :archived, -> {
          AdminUser.where.not(archived_at: nil)
        }

  has_many :full_time_periods
  accepts_nested_attributes_for :full_time_periods, allow_destroy: true

  has_many :gifted_profit_shares
  accepts_nested_attributes_for :gifted_profit_shares, allow_destroy: true

  has_many :pre_profit_share_purchases
  accepts_nested_attributes_for :pre_profit_share_purchases, allow_destroy: true

  has_many :admin_user_gender_identities
  has_many :gender_identities, through: :admin_user_gender_identities

  has_many :admin_user_communities
  has_many :communities, through: :admin_user_communities

  has_many :admin_user_racial_backgrounds
  has_many :racial_backgrounds, through: :admin_user_racial_backgrounds

  has_many :admin_user_cultural_backgrounds
  has_many :cultural_backgrounds, through: :admin_user_cultural_backgrounds

  enum old_skill_tree_level: {
    junior_1: 0,
    junior_2: 1,
    junior_3: 2,
    mid_level_1: 3,
    mid_level_2: 4,
    mid_level_3: 5,
    experienced_mid_level_1: 6,
    experienced_mid_level_2: 7,
    experienced_mid_level_3: 8,
    senior_1: 9,
    senior_2: 10,
    senior_3: 11,
    senior_4: 12,
    lead_1: 13,
    lead_2: 14,
  }

  # Include default devise modules. Others available are:
  # :confirmable, :lockable, :timeoutable, :trackable and :omniauthable
  devise :database_authenticatable,
         :recoverable, :rememberable, :validatable,
         :omniauthable, omniauth_providers: %i[google_oauth2]

  has_many :reviews
  has_many :peer_reviews

  def working_days_between(period_start, period_end)
    period_stop = period_end > Date.today ? period_end : Date.today

    period_range = (period_start..period_end)
    full_time_ranges = full_time_periods.reduce([]) do |acc, ftp|
      acc << (ftp.started_at..(ftp.ended_at || period_stop))
      acc
    end

    overlaps =
      full_time_ranges.reduce([]){|acc, r| [*acc, *(r.to_a & period_range.to_a)]}

    overlaps.select do |d|
      last_friday_of_month = Date.new(d.year, d.month, -1)
      last_friday_of_month -= (last_friday_of_month.wday - 5) % 7
      next false if d == last_friday_of_month

      ftp = full_time_periods.find{|ftp| (ftp.started_at <= d) && (ftp.ended_at == nil || ftp.ended_at >= d)}
      if ftp.multiplier == 0.8
        (1..4).include?(d.wday)
      else
        (1..5).include?(d.wday)
      end
    end
  end

  #def average_utilization
  #  utilization_pass = UtilizationPass.first

  #  data = utilization_pass.data.keys.reduce([]) do |acc, year|
  #    months = utilization_pass.data[year].keys.sort do |a, b|
  #      Date::MONTHNAMES.index(a.capitalize) <=> Date::MONTHNAMES.index(b.capitalize)
  #    end
  #    month_utilizations = [*acc, *months.reduce([]) do |agr, month|
  #      data = utilization_pass.data[year][month][email]
  #      next agr unless data.present?

  #      start_of_month = Date.new(year.to_i, Date::MONTHNAMES.index(month.capitalize), 1)
  #      next agr if Date.today.beginning_of_month == start_of_month
  #      next agr if start_of_month < Date.new(2021, 6, 1)

  #      working_days = working_days_between(start_of_month, start_of_month.end_of_month)
  #      max_possible_hours = (working_days.count * 8)
  #      next agr unless max_possible_hours > 0

  #      billable_hours = data["billable"].reduce(0){|acc, r| acc += r["allocation"]}
  #      agr << (billable_hours / max_possible_hours)
  #      agr
  #    end]
  #  end

  #  return 0.0 unless data.any?
  #  data.reduce(:+) / data.length
  #end

  def psu_earned_by(date = Date.today)
    return :no_data if full_time_periods.empty?

    gifted = (gifted_profit_shares.map do |gps|
      gps.amount
    end).reduce(:+) || 0

    total = ((full_time_periods.map do |ftp|
      ended_at = (ftp.ended_at.present? ? ftp.ended_at : date)
      psu = Stacks::Utils.full_months_between(ended_at, ftp.started_at) * ftp.multiplier
      if psu < 0
        0.0
      else
        psu
      end
    end).reduce(:+) + gifted)

    if total >= 48
      48.0
    else
      total
    end
  end

  def projected_psu_by_eoy
    # We calculate PSU at the 15th of december
    psu_earned_by(Date.new(Date.today.year, 12, 15))
  end

  def pre_profit_share_spent_during(year)
    pre_profit_share_purchases
      .where(purchased_at: Date.new(year, 1, 1).beginning_of_year..Date.new(year, 1, 1).end_of_year)
      .map(&:amount)
      .reduce(:+) || 0
  end

  def profit_shares
    year = 2021
    data = []

    while year <= Date.today.year
      profit_share_pass =
        ProfitSharePass
          .finalized
          .find { |psp|
            (Date.parse(psp.snapshot["finalized_at"]).year == 2021)
          }
      psu_value = profit_share_pass.make_scenario.actual_value_per_psu
      psu_earnt = psu_earned_by(Date.new(year, 12, 15))
      pre_spent_profit_share = pre_profit_share_spent_during(year)

      data << {
        year: year,
        psu_value: psu_value,
        psu_earnt: psu_earnt,
        pre_spent_profit_share: pre_spent_profit_share,
        total_payout: (psu_value * psu_earnt) - pre_spent_profit_share
      }

      year += 1
    end

    data
  end

  def should_nag_for_dei_data?
    (racial_backgrounds.length === 0 ||
     cultural_backgrounds.length === 0 ||
     gender_identities.length === 0)
  end

  def skill_tree_level_without_salary
    latest_review = archived_reviews.first
    if latest_review.present?
      "#{latest_review.level[:name]}"
    else
      if old_skill_tree_level.present?
        level = Review::LEVELS[old_skill_tree_level.to_sym]
        "#{level[:name]}"
      else
        "No Reviews Yet"
      end
    end
  end

  def skill_tree_level
    latest_review = archived_reviews.first
    if latest_review.present?
      "#{latest_review.level[:name]} ($#{latest_review.level[:salary].to_s(:delimited)})"
    else
      if old_skill_tree_level.present?
        level = Review::LEVELS[old_skill_tree_level.to_sym]
        "#{level[:name]} ($#{level[:salary].to_s(:delimited)})"
      else
        "No Reviews Yet"
      end
    end
  end

  def archived_reviews
    reviews.where.not(archived_at: nil).order("archived_at DESC")
  end

  def previous_tree_used
    latest_review = archived_reviews.first
    return nil unless latest_review.present?

    latest_review.workspace.score_trees.map(&:tree).find do |t|
      Tree.craft_trees.include?(t)
    end
  end

  def is_payroll_manager?
    roles.include?("payroll_manager")
  end

  def is_utilization_manager?
    roles.include?("utilization_manager")
  end

  def is_profit_share_manager?
    roles.include?("profit_share_manager")
  end

  def display_name
    email
  end

  # Devise override to ignore the password requirement if the user is authenticated with Google
  def password_required?
    provider.present? ? false : super
  end

  def self.total_projected_psu_issued_by_eoy
    AdminUser.active.map{|a| a.projected_psu_by_eoy }.reject{|v| v == :no_data}.reduce(:+)
  end

  def self.from_omniauth(auth)
    user = where(email: auth.info.email).first || where(auth.slice(:provider, :uid).to_h).first || new
    user.update_attributes provider: auth.provider,
                           uid: auth.uid,
                           email: auth.info.email
    user
  end
end
