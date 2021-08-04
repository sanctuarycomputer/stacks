class AdminUser < ApplicationRecord
  scope :active, -> {
          AdminUser.where(archived_at: nil)
        }
  scope :archived, -> {
          AdminUser.where.not(archived_at: nil)
        }

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

  def skill_tree_level
    latest_review = archived_reviews.first
    if latest_review.present?
      "#{latest_review.level[:name]} ($#{latest_review.level[:salary].to_s(:delimited)})"
    else
      if old_skill_tree_level.present?
        level = Review::LEVELS[AdminUser.find("1").old_skill_tree_level.to_sym]
        "#{level[:name]} ($#{level[:salary].to_s(:delimited)})"
      else
        "No Reviews Yet"
      end
    end
  end

  def archived_reviews
    reviews.where.not(archived_at: nil).order("archived_at DESC")
  end

  def is_payroll_manager?
    roles.include?("payroll_manager")
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
                           email: auth.info.email
    user
  end
end
