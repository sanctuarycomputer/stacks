class Notification < ApplicationRecord
  include Noticed::Model
  belongs_to :recipient, polymorphic: true

  def display_name
    to_notification.try(:topic)
  end
end
