class Community < ApplicationRecord
  class << self
    def seed
      create!(name: "LGBTQIA")
      create!(name: "Disability")
      create!(name: "Neurodiverse")
    end
  end
end
