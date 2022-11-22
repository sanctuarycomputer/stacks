class MailingList < ApplicationRecord
  belongs_to :studio
  has_many :mailing_list_subscribers, dependent: :destroy

  enum provider: {
    substack: 0,
    mailchimp: 1,
  }
end
