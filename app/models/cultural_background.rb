class CulturalBackground < ApplicationRecord
  class << self
    def seed
      create!(name: "Indigenous American", opt_out: false)
      create!(name: "US American", opt_out: false)
      create!(name: "Hispanic, Latino", opt_out: false)
      create!(name: "South American", opt_out: false)
      create!(name: "African", opt_out: false)
      create!(name: "Middle Eastern, North African or Western Asian", opt_out: false)
      create!(name: "Asian", opt_out: false)
      create!(name: "South Asian", opt_out: false)
      create!(name: "European", opt_out: false)
      create!(name: "Eastern European", opt_out: false)
      create!(name: "Multinational Mix", opt_out: false)

      create!(name: "Not sure/still thinking about it", opt_out: true)
      create!(name: "Prefer not to say", opt_out: true)
    end
  end
end
