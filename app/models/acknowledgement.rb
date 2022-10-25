class Acknowledgement < ApplicationRecord
  validates :name, presence: :true
  validates :learn_more_url, format: URI::regexp(%w[http https])
  enum acknowledgement_type: {
    code_of_conduct: 0,
  }
end
