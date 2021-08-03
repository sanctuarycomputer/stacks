class AdminUser < ApplicationRecord
  scope :active, -> {
          AdminUser.where(archived_at: nil)
        }
  scope :archived, -> {
          AdminUser.where.not(archived_at: nil)
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
      "No Reviews Yet"
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
