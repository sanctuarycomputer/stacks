class RacialBackground < ApplicationRecord
  class << self
    def seed
      create!(
        name: "Hispanic, Latinx, or Spanish Origin",
        description: "Mexican or Mexican-American, Puerto Rican, Dominican, Colombian, etc",
        opt_out: false,
      )
      create!(
        name: "Black or African",
        description: "Jamaican, Haitian, Nigerian, Somalian, Ethiopian, etc",
        opt_out: false,
      )
      create!(
        name: "White",
        description: "English, Irish, German, Italian, French, etc",
        opt_out: false,
      )
      create!(
        name: "American Indian or Alaska Native",
        description: "Navajo Nation, Blackfeet Tribe, Mayan, Aztec, Nome Eskimo Community, etc",
        opt_out: false,
      )
      create!(
        name: "Middle Eastern or North African",
        description: "Lebanese, Iranian, Egyptian, Syrian, Moroccan, etc",
        opt_out: false,
      )
      create!(
        name: "Native Hawaiian or other Pacific Islander",
        description: "Somoan, Chamorro, Tongan, Fijian, etc",
        opt_out: false,
      )
      create!(
        name: "Asian or North/East/South/West Asian",
        description: "Chinese, Filipino, Vietnamese, Korean, Japanese, Indian, Pakistan, etc",
        opt_out: false,
      )

      create!(name: "Not sure/still thinking about it", opt_out: true)
      create!(name: "Prefer not to say", opt_out: true)
    end
  end
end
