class AdminUser < ApplicationRecord
  has_many :notifications, as: :recipient
  has_many :full_time_periods, -> { order(started_at: :asc) }, dependent: :delete_all

  # TODO: Keep here until migration has run
  enum contributor_type: {
    core: 0,
    satellite: 1,
    bot: 2,
  }

  scope :active, -> {
    joins(:full_time_periods).where("started_at <= ? AND coalesce(ended_at, 'infinity') >= ?", Date.today, Date.today)
  }
  scope :inactive, -> {
    where.not(id: active)
  }
  scope :ignored, -> {
    where(ignore: true)
  }
  scope :not_ignored, -> {
    where.not(id:ignored)
  }
  scope :admin , -> {
    AdminUser.where(roles: ["admin"])
  }
  
  def active?
    AdminUser.active.include?(self)
  end

  def archived?
    !AdminUser.active.include?(self)
  end

  def full_time_periods
    @_full_time_periods ||= super
  end

  def met_associates_skill_band_requirement_at
    min_points = Review::LEVELS[:senior_2][:min_points]
    # Find the first review that was above the requirement
    first_review_above_requirement =
      archived_reviews.reverse.find do |r|
        r.total_points >= min_points
      end
    if first_review_above_requirement.try(:archived_at)
      return first_review_above_requirement.archived_at
    end

    # Not found, so check if the old_skill_tree_level counts
    if old_skill_tree_level.present? && Review::LEVELS[old_skill_tree_level.to_sym][:min_points] >= min_points
      full_time_periods.order("started_at ASC").first.try(:started_at)
    end
  end

  def met_associates_psu_requirement_at
    psu_required = 48

    achieved_at = nil
    full_time_periods.order("started_at ASC").each do |ftp|
      next if achieved_at.present?
      day = ftp.started_at
      until achieved_at.present? || day == ftp.ended_at_or_now do
        achieved_at = day if psu_earned_by(day) == psu_required
        day += 1.days
      end
    end
    achieved_at
  end

  def contiguous_psu_earning_periods_until(date = Date.today)
    full_time_periods.select{|ftp| ["five_day", "four_day"].include?(ftp.contributor_type)}.reduce([]) do |acc, ftp|
      if acc.empty?
        # This is the first ftp, stash it.
        next acc << {ftps: [ftp], started_at: ftp.started_at, ended_at: ftp.ended_at_or(date) }
      end

      if (acc.last[:ended_at] + 1.day != ftp.started_at)
        # This ftp is not contiguous, break it.
        next acc << {ftps: [ftp], started_at: ftp.started_at, ended_at: ftp.ended_at_or(date) }
      end

      if (acc.last[:ftps].last.contributor_type != ftp.contributor_type)
        # The PSU earn rate changed, break it.
        next acc << {ftps: [ftp], started_at: ftp.started_at, ended_at: ftp.ended_at_or(date) }
      end

      # This is contiguous! Combine them.
      acc.last[:ftps] << ftp
      acc.last[:ended_at] = ftp.ended_at_or(date)
      acc
    end
  end

  def psu_earned_by(date = Date.today)
    psu_earning_periods = contiguous_psu_earning_periods_until(date)
    return nil if psu_earning_periods.empty?

    ftp = full_time_period_at(date)
    return nil unless ftp.present?
    return nil unless ["five_day", "four_day"].include?(ftp.contributor_type)

    total = psu_earning_periods.reduce(0) do |acc, psuep|
      ended_at = psuep[:ended_at] <= date ? psuep[:ended_at] : date
      next acc if ended_at < psuep[:started_at]

      psu = psuep[:ftps].last.psu_earn_rate * Stacks::Utils.full_months_between(ended_at, psuep[:started_at])

      # If there is a psuep before this one, check if it was contiguous
      # (which means the contributor_type changed) and if so, add the remainder
      # so that the user doesn't lose out on the difference
      remainder = 0
      if psu_earning_periods.index(psuep) > 0
        prev_psuep = psu_earning_periods[psu_earning_periods.index(psuep) - 1]
        prev_psu_earn_rate = prev_psuep[:ftps].last.psu_earn_rate

        if prev_psuep[:ended_at] + 1.day == psuep[:started_at]
          # Count the amount of days between the anchor date and the
          # date that this period ended at.
          remainder_days = 1.0 # Start at 1 to capture to final day of this period
          running_date = prev_psuep[:ended_at]
          while (running_date.day != prev_psuep[:started_at].day) do
            remainder_days += 1
            running_date = running_date - 1.day
          end
          remainder =
            (remainder_days / Time.days_in_month(prev_psuep[:ended_at].month, prev_psuep[:ended_at].year)) * prev_psu_earn_rate
        end
      end

      psu += remainder
      acc += (psu < 0 ? 0.0 : psu)
    end

    gifted =
      gifted_profit_shares.reduce(0){|acc, gps| acc += gps.amount}
    total += gifted
    (total >= 48 ? 48.0 : total).round(2)
  end

  def projected_psu_by_eoy
    # We calculate PSU at the 15th of december
    psu_earned_by(Date.new(Date.today.year, 12, 15))
  end

  def psu_audit_log
    full_time_periods.map do |ftp|
      log =
        (ftp.started_at..ftp.ended_at_or_now).reduce({}) do |acc, date|
          psu = psu_earned_by(date)
          acc[psu] = { date: date } unless acc.keys.include?(psu)
          acc
        end
      { ftp: ftp, log: log }
    end
  end

  def met_associates_requirements_at
    skill_band_met_at = met_associates_skill_band_requirement_at
    return nil unless skill_band_met_at

    psu_requirement_met_at = met_associates_psu_requirement_at
    return nil unless psu_requirement_met_at

    [psu_requirement_met_at, skill_band_met_at].max.to_date
  end

  def atc_months
    # TODO: Take into account wether this user is active or not
    atc_periods.reduce(0.0) do |acc, atcp|
      acc +=
        (((atcp.period_ended_at || Date.today).to_time - atcp.period_started_at.to_time)/1.month.second)
    end
  end

  def studio_coordinator_months
    # TODO: Take into account wether this user is active or not
    studio_coordinator_periods.reduce(0.0) do |acc, scp|
      acc +=
        ((scp.ended_at_or_now.to_time - scp.started_at.to_time)/1.month.second)
    end
  end

  has_many :atc_periods, dependent: :nullify
  has_many :studio_coordinator_periods, dependent: :nullify

  has_many :invoice_trackers, dependent: :nullify
  has_one :forecast_person, class_name: "ForecastPerson", foreign_key: "email", primary_key: "email"

  accepts_nested_attributes_for :full_time_periods, allow_destroy: true

  has_many :gifted_profit_shares, dependent: :delete_all
  accepts_nested_attributes_for :gifted_profit_shares, allow_destroy: true

  has_many :pre_profit_share_purchases, dependent: :delete_all
  accepts_nested_attributes_for :pre_profit_share_purchases, allow_destroy: true

  has_many :studio_memberships, dependent: :delete_all
  has_many :studios, through: :studio_memberships

  has_many :admin_user_gender_identities, dependent: :delete_all
  has_many :gender_identities, through: :admin_user_gender_identities

  has_many :admin_user_communities, dependent: :delete_all
  has_many :communities, through: :admin_user_communities

  has_many :admin_user_racial_backgrounds, dependent: :delete_all
  has_many :racial_backgrounds, through: :admin_user_racial_backgrounds

  has_many :admin_user_cultural_backgrounds, dependent: :delete_all
  has_many :cultural_backgrounds, through: :admin_user_cultural_backgrounds

  has_many :admin_user_interests, dependent: :delete_all
  has_many :interests, through: :admin_user_interests


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

  def current_contributor_type
    latest_full_time_period.try(:contributor_type)
  end

  def expected_utilization
    latest_full_time_period.try(:expected_utilization) || 0.8
  end

  def expected_utilization_at(date = Date.today)
    full_time_period_at(date).try(:expected_utilization) || 0
  end

  def full_time_period_at(date = Date.today)
    # If the latest_full_time_period is not ended, and the date is in the future
    # assume the individual will not quit, and their FTP won't change (so we can
    # project out PSU by the EOY)
    if date > Date.today
      latest = latest_full_time_period
      return latest if latest.ended_at.nil?
    end
    full_time_periods.find do |ftp|
      ftp.started_at <= date && ftp.ended_at_or_now >= date
    end
  end

  def latest_full_time_period
    return full_time_periods.first if full_time_periods.length < 2

    full_time_periods.reduce(nil) do |acc, ftp|
      if acc.present?
        if (ftp.ended_at || Date.today) > (acc.ended_at || Date.today)
          ftp
        else
          acc
        end
      else
        ftp
      end
    end
  end

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
      #unless consider_freedom_friday_a_working_day
      #  last_friday_of_month = Date.new(d.year, d.month, -1)
      #  last_friday_of_month -= (last_friday_of_month.wday - 5) % 7
      #  next false if d == last_friday_of_month
      #end

      ftp = full_time_periods.find do |ftp|
        (ftp.started_at <= d) && (ftp.ended_at == nil || ftp.ended_at >= d)
      end

      if ftp.contributor_type == "four_day"
        (1..4).include?(d.wday)
      else
        (1..5).include?(d.wday)
      end
    end
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
            (Date.parse(psp.snapshot["finalized_at"]).year == year)
          }
      unless profit_share_pass.present?
        year += 1
        next
      end
      psu_value = profit_share_pass.make_scenario.actual_value_per_psu
      psu_earnt = psu_earned_by(Date.new(year, 12, 15))
      psu_earnt = 0 if psu_earnt == nil
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

  def should_nag_for_skill_tree?
    system = System.instance
    if archived_reviews.any?
      (Date.today - archived_reviews.first.archived_at.to_date).to_i >
        system.expected_skill_tree_cadence_days
    elsif latest_full_time_period.present?
      (Date.today - latest_full_time_period.started_at).to_i >
        system.expected_skill_tree_cadence_days
    end
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

  def skill_tree_level_on_date(date)
    latest_review_before_date =
      archived_reviews
        .order(archived_at: :desc)
        .where("archived_at <= ?", date)
        .first

    if latest_review_before_date.present?
      latest_review_before_date.level
    elsif old_skill_tree_level.present?
      Review::LEVELS[old_skill_tree_level.to_sym]
    else
      AdminUser.default_skill_level
    end
  end

  def self.default_skill_level
    Review::LEVELS[:senior_1]
  end

  def self.default_cost_of_employment_on_date(date)
    yearly_cost =
      AdminUser.default_skill_level[:salary]
    business_days =
      Stacks::Utils.business_days_between(date.beginning_of_year, date.end_of_year)
    (yearly_cost / business_days) * 1.2 # employment taxes & healthcare
  end

  def cost_of_employment_on_date(date)
    yearly_cost =
      skill_tree_level_on_date(date)[:salary]
    business_days =
      Stacks::Utils.business_days_between(date.beginning_of_year, date.end_of_year)
    (yearly_cost / business_days) * 1.2 # employment taxes & healthcare
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

  def is_admin?
    roles.include?("admin")
  end

  def display_name
    email
  end

  # Devise override to ignore the password requirement if the user is authenticated with Google
  def password_required?
    provider.present? ? false : super
  end

  def self.from_omniauth(auth)
    user = where(email: auth.info.email).first || where(auth.slice(:provider, :uid).to_h).first || new
    user.update_attributes provider: auth.provider,
                           uid: auth.uid,
                           email: auth.info.email,
                           info: auth.dig("info")
    user
  end
end
