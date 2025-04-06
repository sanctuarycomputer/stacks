class AdminUser < ApplicationRecord
  has_many :notifications, as: :recipient, dependent: :delete_all
  has_many :full_time_periods, -> { order(started_at: :asc) }, dependent: :delete_all
  has_one :associates_award_agreement, dependent: :delete
  validate :all_but_latest_full_time_periods_are_closed?

  has_many :project_lead_periods, dependent: :delete_all
  has_many :studio_coordinator_periods, dependent: :delete_all # TODO Remove me
  has_many :creative_lead_periods
  has_many :technical_lead_periods
  has_many :project_safety_representative_periods

  has_many :collective_role_holder_periods

  has_many :invoice_trackers, dependent: :nullify
  has_one :forecast_person, class_name: "ForecastPerson", foreign_key: "email", primary_key: "email"

  accepts_nested_attributes_for :full_time_periods, allow_destroy: true

  has_many :gifted_profit_shares, dependent: :delete_all
  accepts_nested_attributes_for :gifted_profit_shares, allow_destroy: true

  has_many :pre_profit_share_purchases, dependent: :nullify
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

  has_many :admin_user_salary_windows, dependent: :delete_all

  belongs_to :github_user, class_name: "GithubUser", foreign_key: "github_user_id", optional: true
  has_many :github_pull_requests, through: :github_user
  has_many :zenhub_issues, through: :github_user

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

  has_many :reviews, dependent: :nullify
  has_many :peer_reviews, dependent: :nullify

  after_create :sync_salary_windows!

  def self.find_or_create_by_g3d_uid!(email)
    return nil unless (email.ends_with?("@sanctuary.computer") || email.ends_with?("@xxix.co"))

    uid = email.split("@")[0]
    existing = [
      AdminUser.find_by(email: "#{uid}@xxix.co"),
      AdminUser.find_by(email: "#{uid}@sanctuary.computer")
    ].compact[0]
    return existing if existing.present?
    AdminUser.find_or_create_by!(
      email: email,
      provider: "google_oauth2"
    )
  end

  def project_roles_in_period(period)
    [
      project_lead_periods,
      creative_lead_periods,
      technical_lead_periods,
    ].flatten.select do |p|
      p.effective_days_in_role_during_range(period.starts_at, period.ends_at) > 0
    end
  end

  def collective_roles_in_period(period)
    collective_role_holder_periods.select do |p|
      p.effective_days_in_role_during_range(period.starts_at, period.ends_at) > 0
    end
  end

  def approximate_cost_per_hour_before_studio_expenses
    date = Date.today.beginning_of_week
    hours_per_day = 8
    cost_of_employment_on_date(date) / hours_per_day
  end

  def is_employed_on_date?(date)
    full_time_period_at(date).present?
  end

  def sellable_hours_for_date(date)
    ftp = full_time_period_at(date)
    return nil unless ftp.present?

    is_working_day =
      (ftp.four_day? && (1..4).include?(date.wday)) ||
      (ftp.five_day? && (1..5).include?(date.wday))

    return nil unless is_working_day

    {
      sellable: 8 * ftp.expected_utilization,
      non_sellable: 8 - (8 * ftp.expected_utilization)
    }
  end

  def sellable_hours_for_period(period)
    (period.starts_at..period.ends_at).reduce({
      sellable: 0,
      non_sellable: 0
    }) do |acc, date|
      data = sellable_hours_for_date(date)
      next acc unless data.present?
      acc[:sellable] += data[:sellable]
      acc[:non_sellable] += data[:non_sellable]
      acc
    end
  end

  def is_associate?
    return true if email == "hugh@sanctuary.computer"
    return false unless associates_award_agreement.present?
    associates_award_agreement.try(:started_at) >= Date.today
  end

  def all_but_latest_full_time_periods_are_closed?
    all_closed = full_time_periods.reject{|ftp| ftp == latest_full_time_period}.all? do |ftp|
      ftp.ended_at.present?
    end

    if !all_closed
      errors.add(:base, "another full_time_period is open")
    end
  end

  # TODO: Keep here until migration has run
  enum contributor_type: {
    core: 0,
    satellite: 1,
    bot: 2,
  }

  scope :active, -> {
    joins(:full_time_periods).where("full_time_periods.started_at <= ? AND coalesce(full_time_periods.ended_at, 'infinity') >= ?", Date.today, Date.today)
  }
  scope :associates, -> {
    joins(:associates_award_agreement).where("associates_award_agreements.started_at <= ?", Date.today)
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
  scope :core, -> {
    joins(:full_time_periods).where(
      "full_time_periods.contributor_type = ? OR full_time_periods.contributor_type = ?",
      FullTimePeriod.contributor_types[Enum::ContributorType::FIVE_DAY],
      FullTimePeriod.contributor_types[Enum::ContributorType::FOUR_DAY]
    ).uniq
  }

  def should_nag_for_survey_responses?
    survey_needing_response =
      Survey.open.find do |s|
        s.expected_responders.include?(self) && SurveyResponder.find_by(survey: s, admin_user: self).nil?
      end
    survey_needing_response.present?
  end

  def name
    email
  end

  def external_link
    "/admin/admin_users/#{id}"
  end

  def active?
    AdminUser.active.include?(self)
  end

  def archived?
    !AdminUser.active.include?(self)
  end

  # def full_time_periods
  #   @_full_time_periods ||= super
  # end

  def considered_temporary?
    full_time_periods.map(&:considered_temporary).all?
  end

  def start_date
    full_time_periods.order("started_at ASC").first.try(:started_at) || created_at.to_date
  end

  def left_at
    full_time_periods.order("started_at ASC").last.try(:ended_at) || nil
  end

  def met_associates_skill_band_requirement_at
    # Find the first review that was above the requirement
    first_review_above_requirement = archived_reviews.reverse.find do |r|
      level = Stacks::SkillLevelFinder.find!(r.archived_at, :senior_2)
      r.total_points >= level[:min_points]
    end

    if first_review_above_requirement.try(:archived_at)
      return first_review_above_requirement.archived_at
    end

    # Check if the old_skill_tree_level counts.
    if old_skill_tree_level.blank?
      return nil
    end

    min_level = Stacks::SkillLevelFinder.find!(start_date, :senior_2)
    actual_level = Stacks::SkillLevelFinder.find!(start_date, old_skill_tree_level)

    if actual_level[:min_points] >= min_level[:min_points]
      start_date
    end
  end

  def met_associates_psu_requirement_at
    psu_required = 48

    achieved_at = nil
    full_time_periods.order("started_at ASC").each do |ftp|
      next if achieved_at.present?
      day = ftp.started_at
      until achieved_at.present? || day == ftp.period_ended_at do
        achieved_at = day if psu_earned_by(day) == psu_required
        day += 1.days
      end
    end
    achieved_at
  end

  def contiguous_psu_earning_periods_until(date = Date.today)
    full_time_periods.select{|ftp| ftp.four_day? || ftp.five_day? }.reduce([]) do |acc, ftp|
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
    return nil unless ftp.four_day? || ftp.five_day?

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
        (ftp.started_at..ftp.period_ended_at).reduce({}) do |acc, date|
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

  def time_in_days_since_last_project_lead_role
    return Float::INFINITY if project_lead_periods.empty?
    (Date.today - project_lead_periods.map(&:period_ended_at).max).to_i
  end

  def total_time_in_days_holding_project_lead_role
    project_lead_periods.reduce(0) do |acc, plp|
      acc += plp.time_held_in_days
    end
  end

  def project_lead_months
    # TODO: Take into account wether this user is active or not
    project_lead_periods.reduce(0.0) do |acc, p|
      acc +=
        (((p.period_ended_at).to_time - p.period_started_at.to_time)/1.month.second)
    end
  end

  def studio_coordinator_months
    # TODO: Take into account wether this user is active or not
    studio_coordinator_periods.reduce(0.0) do |acc, scp|
      acc +=
        ((scp.period_ended_at.to_time - scp.started_at.to_time)/1.month.second)
    end
  end

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

      if latest.present? && latest.ended_at.nil?
        return latest
      end
    end

    full_time_periods.find do |ftp|
      ftp.started_at <= date && ftp.period_ended_at >= date
    end
  end

  def latest_full_time_period
    return full_time_periods.first if full_time_periods.length < 2

    # Almost def a better way to do this with a quick sort & pluck
    full_time_periods.reduce(nil) do |acc, ftp|
      next ftp unless acc.present?
      (ftp.started_at > acc.started_at) ? ftp : acc
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

      if ftp.four_day?
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
        level = Stacks::SkillLevelFinder.find!(Date.today, old_skill_tree_level)
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
        level = Stacks::SkillLevelFinder.find!(Date.today, old_skill_tree_level)
        "#{level[:name]} ($#{level[:salary].to_s(:delimited)})"
      else
        "No Reviews Yet"
      end
    end
  end

  def skill_tree_level_on_date(date)
    latest_review = latest_review_before_date(date)
    if latest_review.present?
      latest_review.level
    elsif old_skill_tree_level.present?
      Stacks::SkillLevelFinder.find!(date, old_skill_tree_level)
    else
      AdminUser.default_skill_level
    end
  end

  def latest_review_before_date(date)
    archived_reviews
      .order(archived_at: :desc)
      .where("archived_at <= ?", date)
      .first
  end

  def skill_tree_points_on_date(date)
    latest_review = latest_review_before_date(date)
    if latest_review.present?
      latest_review.total_points
    elsif old_skill_tree_level.present?
      Stacks::SkillLevelFinder.find!(date, old_skill_tree_level)[:min_points]
    else
      AdminUser.default_skill_level[:min_points]
    end
  end

  def self.default_skill_level
    Stacks::SkillLevelFinder.find!(Date.today, :senior_1)
  end

  def self.default_cost_of_employment_on_date(date)
    yearly_cost =
      AdminUser.default_skill_level[:salary]
    business_days =
      Stacks::Utils.business_days_between(date.beginning_of_year, date.end_of_year)
    (yearly_cost / business_days) * 1.1 # employment taxes & healthcare
  end

  def cost_of_employment_on_date(date)
    salary_window = admin_user_salary_windows.find_by(
      "start_date <= ? AND (end_date >= ? OR end_date IS NULL)",
      date,
      date
    )

    yearly_cost = if salary_window.nil?
      skill_tree_level_on_date(date)[:salary]
    else
      salary_window.salary
    end

    ftp = full_time_period_at(date)

    business_days =
      Stacks::Utils.business_days_between(date.beginning_of_year, date.end_of_year)

    # TODO: Actually calculate the number of non-Friday business days.
    if ftp.present? && ftp.four_day?
      business_days *= 0.8
    end

    (yearly_cost / business_days) * 1.1 # employment taxes & healthcare
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
    uid = auth.info.email.split("@")[0]
    user = where(email: "#{uid}@sanctuary.computer").first || where(email: "#{uid}@xxix.co").first || where(auth.slice(:provider, :uid).to_h).first || new
    user.update_attributes provider: auth.provider,
                           uid: auth.uid,
                           email: auth.info.email,
                           info: auth.dig("info")
    user
  end

  def sync_salary_windows!
    syncer = Stacks::AdminUserSalaryWindowSyncer.new(self)
    syncer.sync!
  end

  def key_metrics_for_period(period, gradation)
    closed_issues = zenhub_issues.closed.where(closed_at: period.starts_at..period.ends_at)

    prs = github_pull_requests.merged.where(merged_at: period.starts_at..period.ends_at)
    ttm = prs.average(:time_to_merge)
    g3d = Studio.garden3d
    g3d_data = g3d.snapshot[gradation].find{|g| g["label"] == period.label}

    data = {
      skill_points: {
        value: skill_tree_points_on_date(period.ends_at),
        unit: :count
      },
      story_points: {
        value: closed_issues.sum(:estimate),
        unit: :count
      },
      prs_merged: {
        value: prs.count,
        unit: :count
      },
      time_to_merge_pr: {
        value: ttm.present? ? (ttm / 86400.to_f) : nil,
        unit: :days
      },
      billable: {
        value: nil,
        unit: :hours
      },
      sellable: {
        value: nil,
        unit: :hours
      },
      time_off: {
        value: nil,
        unit: :hours
      },
      non_billable: {
        value: nil,
        unit: :hours
      },
      non_sellable: {
        value: nil,
        unit: :hours
      },
    }

    _email, v = g3d_data["utilization"].find{|k,v| k == self.email}
    if v.present?
      data = data.merge({
        billable: {
          value: v["billable"].values.reduce(0){|acc, d| acc += d.to_f },
          unit: :hours
        },
        sellable: {
          value: v["sellable"].try(:to_f),
          unit: :hours
        },
        time_off: {
          value: v["time_off"].try(:to_f),
          unit: :hours
        },
        non_billable: {
          value: v["non_billable"].try(:to_f),
          unit: :hours
        },
        non_sellable: {
          value: v["non_sellable"].try(:to_f),
          unit: :hours
        },
      })
    end

    data
  end
end
