class GenderIdentity < ApplicationRecord
  class << self
    def seed
      create!(name: "Female", opt_out: false)
      create!(name: "Male", opt_out: false)
      create!(name: "Genderqueer/Genderfluid", opt_out: false)
      create!(name: "Non-binary", opt_out: false)
      create!(name: "Transgender", opt_out: false)
      create!(name: "Cisgender", opt_out: false)
      create!(name: "Agender", opt_out: false)

      create!(name: "Not sure/still thinking about it", opt_out: true)
      create!(name: "Prefer not to say", opt_out: true)
    end
  end
end
