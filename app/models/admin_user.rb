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

  def sellable_days_between(period_start, period_end)
    total = (full_time_periods.map do |ftp|
      next 0 if ftp.ended_at.present? && ftp.ended_at < period_start
      started =
        period_start >= ftp.started_at ? period_start : ftp.started_at
      ended =
        ftp.ended_at.nil? ? period_end : ftp.ended_at
      ((started..ended).select do |d|
        (1..4).include?(d.wday)
      end).size
    end).compact.reduce(:+) || 0

    # We give roughly 40 days PTO a year
    # Plus 7 mental health days
    (total - 37 - 7)
  end

  def projected_psu_by_eoy
    # We calculate PSU at the 15th of december
    psu_earned_by(Date.new(Date.today.year, 12, 15))
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

  def self.total_projected_business_days_by_eoy
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
