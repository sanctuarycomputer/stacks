class Stacks::SkillLevelFinder
  def self.find_all!(date)
    self.new(date).find_all!
  end

  def self.find!(date, key)
    self.new(date).find!(key)
  end

  def self.effective_dates
    LEVELS_BY_DATE.keys
  end

  def initialize(date)
    @date = date
  end

  def find_all!
    matching_levels.values
  end

  def find!(key)
    level = matching_levels[key.to_sym]

    if level.nil?
      raise "Unable to find level for date #{@date} and key #{key}"
    end

    level
  end

  private

  def matching_levels
    matching_date = LEVELS_BY_DATE.keys.reverse.find do |date|
      date <= @date
    end

    if matching_date.nil?
      raise "No matching levels found for date #{date}"
    end

    LEVELS_BY_DATE[matching_date]
  end

  LEVELS_BY_DATE = {
    # The original skill levels from the beginning of the company's existence.
    Date.new(1900, 1, 1) => {
      junior_1: {
        name: "J1",
        min_points: 100,
        salary: 60000
      },
      junior_2: {
        name: "J2",
        min_points: 155,
        salary: 63500
      },
      junior_3: {
        name: "J3",
        min_points: 210,
        salary: 67000
      },
      mid_level_1: {
        name: "ML1",
        min_points: 265,
        salary: 70000
      },
      mid_level_2: {
        name: "ML2",
        min_points: 320,
        salary: 73500
      },
      mid_level_3: {
        name: "ML3",
        min_points: 375,
        salary: 77000
      },
      experienced_mid_level_1: {
        name: "EML1",
        min_points: 430,
        salary: 80000
      },
      experienced_mid_level_2: {
        name: "EML2",
        min_points: 485,
        salary: 85000
      },
      experienced_mid_level_3: {
        name: "EML3",
        min_points: 540,
        salary: 90000
      },
      senior_1: {
        name: "S1",
        min_points: 595,
        salary: 95000
      },
      senior_2: {
        name: "S2",
        min_points: 650,
        salary: 100000
      },
      senior_3: {
        name: "S3",
        min_points: 690,
        salary: 105000
      },
      senior_4: {
        name: "S4",
        min_points: 720,
        salary: 110000
      },
      lead_1: {
        name: "L1",
        min_points: 750,
        salary: 115000
      },
      lead_2: {
        name: "L2",
        min_points: 810,
        salary: 120000
      },
    },
    # Updated by commit 51aa4cccf51f9e30698e5628892d4d5e62859b4c
    Date.new(2021, 12, 8) => {
      junior_1: {
        name: "J1",
        min_points: 100,
        salary: 63000
      },
      junior_2: {
        name: "J2",
        min_points: 155,
        salary: 66675
      },
      junior_3: {
        name: "J3",
        min_points: 210,
        salary: 70350
      },
      mid_level_1: {
        name: "ML1",
        min_points: 265,
        salary: 73500
      },
      mid_level_2: {
        name: "ML2",
        min_points: 320,
        salary: 77175
      },
      mid_level_3: {
        name: "ML3",
        min_points: 375,
        salary: 80850
      },
      experienced_mid_level_1: {
        name: "EML1",
        min_points: 430,
        salary: 84000
      },
      experienced_mid_level_2: {
        name: "EML2",
        min_points: 485,
        salary: 89250
      },
      experienced_mid_level_3: {
        name: "EML3",
        min_points: 540,
        salary: 94500
      },
      senior_1: {
        name: "S1",
        min_points: 595,
        salary: 99750
      },
      senior_2: {
        name: "S2",
        min_points: 650,
        salary: 105000
      },
      senior_3: {
        name: "S3",
        min_points: 690,
        salary: 110250
      },
      senior_4: {
        name: "S4",
        min_points: 720,
        salary: 115500
      },
      lead_1: {
        name: "L1",
        min_points: 750,
        salary: 120750
      },
      lead_2: {
        name: "L2",
        min_points: 810,
        salary: 126000
      },
    },
    # Updated by commit a8b51e46f4e92fb110378ef1b599ee21b2cbe747
    Date.new(2022, 7, 5) => {
      junior_1: {
        name: "J1",
        min_points: 100,
        salary: 63000
      },
      junior_2: {
        name: "J2",
        min_points: 155,
        salary: 66675
      },
      junior_3: {
        name: "J3",
        min_points: 210,
        salary: 70350
      },
      mid_level_1: {
        name: "ML1",
        min_points: 265,
        salary: 73500
      },
      mid_level_2: {
        name: "ML2",
        min_points: 320,
        salary: 77175
      },
      mid_level_3: {
        name: "ML3",
        min_points: 375,
        salary: 80850
      },
      experienced_mid_level_1: {
        name: "EML1",
        min_points: 430,
        salary: 84000
      },
      experienced_mid_level_2: {
        name: "EML2",
        min_points: 485,
        salary: 89250
      },
      experienced_mid_level_3: {
        name: "EML3",
        min_points: 540,
        salary: 96862.5
      },
      senior_1: {
        name: "S1",
        min_points: 595,
        salary: 107231.25
      },
      senior_2: {
        name: "S2",
        min_points: 650,
        salary: 118125.00
      },
      senior_3: {
        name: "S3",
        min_points: 690,
        salary: 129543.75
      },
      senior_4: {
        name: "S4",
        min_points: 720,
        salary: 141487.50
      },
      lead_1: {
        name: "L1",
        min_points: 750,
        salary: 153956.25
      },
      lead_2: {
        name: "L2",
        min_points: 810,
        salary: 166950.00
      },
    }
  }.freeze
end
