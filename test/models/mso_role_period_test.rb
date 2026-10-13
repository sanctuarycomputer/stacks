require "test_helper"

class MsoRolePeriodTest < ActiveSupport::TestCase
  def make_contributor(tag)
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000),
                                email: "mso-#{tag}-#{SecureRandom.hex(3)}@example.com", data: {})
    # ForecastPerson's after_create already makes the Contributor.
    fp.contributor || Contributor.create!(forecast_person: fp)
  end

  def build_period(contributor, attrs = {})
    MsoRolePeriod.new({
      contributor: contributor,
      tier: :chief,
      title: "Operations",
      started_at: Date.new(2027, 1, 1),
    }.merge(attrs))
  end

  test "a valid period saves" do
    period = build_period(make_contributor("valid"))
    assert period.save, period.errors.full_messages.to_sentence
  end

  test "tier multipliers are exact decimals" do
    contributor = make_contributor("mult")
    assert_equal BigDecimal("0.70"), build_period(contributor, tier: :head).tier_multiplier
    assert_equal BigDecimal("0.85"), build_period(contributor, tier: :svp).tier_multiplier
    assert_equal BigDecimal("1.00"), build_period(contributor, tier: :chief).tier_multiplier
    assert_equal BigDecimal("1.15"), build_period(contributor, tier: :principal).tier_multiplier
    # 0.85 == BigDecimal("0.85") can be true for a Float, so check the type.
    MsoRolePeriod.tiers.each_key do |tier|
      assert_kind_of BigDecimal, build_period(contributor, tier: tier).tier_multiplier, tier
    end
  end

  test "started_at is required" do
    period = build_period(make_contributor("nostart"), started_at: nil)
    assert_not period.valid?
    assert_includes period.errors[:started_at], "can't be blank"
  end

  test "a missing started_at does not blow up when a sibling exists" do
    contributor = make_contributor("nostart-sibling")
    build_period(contributor).save!
    period = build_period(contributor, started_at: nil)
    assert_not period.valid?
  end

  test "tier is required" do
    period = build_period(make_contributor("notier"), tier: nil)
    assert_not period.valid?
    assert_includes period.errors[:tier], "can't be blank"
  end

  test "title is required" do
    period = build_period(make_contributor("notitle"), title: "")
    assert_not period.valid?
    assert_includes period.errors[:title], "can't be blank"
  end

  test "started_at must be the first day of a month" do
    period = build_period(make_contributor("midstart"), started_at: Date.new(2027, 1, 15))
    assert_not period.valid?
    assert_includes period.errors[:started_at], "must be the first day of the month"
  end

  test "ended_at must be the last day of a month" do
    period = build_period(make_contributor("midend"), ended_at: Date.new(2027, 3, 15))
    assert_not period.valid?
    assert_includes period.errors[:ended_at], "must be the last day of the month"
  end

  test "a period of a single month saves" do
    period = build_period(make_contributor("onemonth"),
                          started_at: Date.new(2027, 1, 1), ended_at: Date.new(2027, 1, 31))
    assert period.save, period.errors.full_messages.to_sentence
    assert_equal 30, period.time_held_in_days
  end

  test "ended_at before started_at is rejected" do
    period = build_period(make_contributor("backwards"),
                          started_at: Date.new(2027, 3, 1), ended_at: Date.new(2027, 1, 31))
    assert_not period.valid?
  end

  test "an existing period can be edited without conflicting with itself" do
    period = build_period(make_contributor("edit"))
    period.save!
    period.title = "Finance"
    assert period.valid?, period.errors.full_messages.to_sentence
  end

  test "a contributor with role periods cannot be destroyed" do
    contributor = make_contributor("keep")
    build_period(contributor).save!
    assert_not contributor.destroy
    assert MsoRolePeriod.exists?(contributor_id: contributor.id)
  end

  test "ended_at on the last day of a month is accepted" do
    period = build_period(make_contributor("goodend"), ended_at: Date.new(2027, 2, 28))
    assert period.valid?, period.errors.full_messages.to_sentence
  end

  test "two overlapping periods for one contributor are rejected" do
    contributor = make_contributor("overlap")
    build_period(contributor, ended_at: Date.new(2027, 6, 30)).save!
    overlapping = build_period(contributor, tier: :svp, started_at: Date.new(2027, 6, 1))
    assert_not overlapping.valid?
    assert_includes overlapping.errors[:base], "This period overlaps with another."
  end

  test "two open-ended periods are rejected even when the second starts in the future" do
    # ActsAsPeriod's default period_ended_at is `ended_at || Date.today`, which
    # makes a future-dated open-ended period look non-overlapping. A promotion
    # entered ahead of time would then leave the person holding two tiers.
    contributor = make_contributor("future")
    build_period(contributor).save!
    promotion = build_period(contributor, tier: :principal,
                             started_at: Date.today.next_year.beginning_of_year)
    assert_not promotion.valid?
    assert_includes promotion.errors[:base], "This period overlaps with another."
  end

  test "a closed period followed by a later open one is accepted" do
    contributor = make_contributor("handoff")
    build_period(contributor, ended_at: Date.new(2027, 6, 30)).save!
    successor = build_period(contributor, tier: :principal, started_at: Date.new(2027, 7, 1))
    assert successor.valid?, successor.errors.full_messages.to_sentence
  end

  test "two contributors may hold periods over the same months" do
    build_period(make_contributor("a")).save!
    assert build_period(make_contributor("b")).valid?
  end

  test "active_during returns periods overlapping the month" do
    closed = build_period(make_contributor("closed"),
                          started_at: Date.new(2027, 1, 1), ended_at: Date.new(2027, 3, 31))
    open = build_period(make_contributor("open"), started_at: Date.new(2027, 3, 1))
    later = build_period(make_contributor("later"), started_at: Date.new(2027, 5, 1))
    [closed, open, later].each(&:save!)

    assert_equal [closed.id, open.id].sort, MsoRolePeriod.active_during(Date.new(2027, 3, 15)).pluck(:id).sort
    assert_equal [open.id], MsoRolePeriod.active_during(Date.new(2027, 4, 1)).pluck(:id)
    assert_equal [closed.id], MsoRolePeriod.active_during(Date.new(2027, 2, 10)).pluck(:id)
    assert_equal [open.id, later.id].sort, MsoRolePeriod.active_during(Date.new(2027, 5, 31)).pluck(:id).sort
  end

  test "a contributor lists its role periods" do
    contributor = make_contributor("assoc")
    period = build_period(contributor)
    period.save!
    assert_equal [period], contributor.mso_role_periods.to_a
  end

  # A start date in an earlier year (a typo) would silently stop the founder
  # true-up for every month since, and take the person out of the benchmark
  # pool for old months.
  test "a period cannot start before the first month MSO compensation is run for" do
    start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START

    [start - 1.month, Date.new(start.year - 10, start.month, 1)].each do |early|
      period = build_period(make_contributor("early"), started_at: early)
      assert_not period.valid?, early.to_s
      assert_match(/cannot be before #{start.strftime('%B %Y')}/, period.errors[:started_at].join)
    end
    assert build_period(make_contributor("first"), started_at: start).valid?
  end

  test "a period already on file with an earlier start can still be ended, but not moved to another early date" do
    start = Mso::ManagementFeeInvoices::MANAGEMENT_FEE_START
    period = build_period(make_contributor("onfile"), started_at: start - 3.months)
    period.save!(validate: false)

    period.ended_at = (start + 2.months).end_of_month
    assert period.valid?, period.errors.full_messages.to_sentence

    period.started_at = start - 2.months
    assert_not period.valid?
  end
end
