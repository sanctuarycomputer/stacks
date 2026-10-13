require "test_helper"

class StacksLearningAutoChecksTest < ActiveSupport::TestCase
  AC = Stacks::Learning::AutoChecks

  def forecast_person_for!(person)
    ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: person.email, data: {})
  end

  test "an unknown key is never passed" do
    assert_not AC.passed?("nope", learning_person!)
  end

  test "forecast_account passes once a Forecast person shares the email" do
    person = learning_person!
    assert_not AC.passed?("forecast_account", person)
    forecast_person_for!(person)
    assert AC.passed?("forecast_account", person.reload)
  end

  test "payment_profile needs a Forecast person and then Deel or a QBO vendor" do
    person = learning_person!
    assert_not AC.passed?("payment_profile", person)
    fp = forecast_person_for!(person)
    assert_not AC.passed?("payment_profile", person.reload)
    fp.contributor.update_column(:deel_person_id, "deel-123")
    assert AC.passed?("payment_profile", person.reload)
  end

  test "human_operating_manual passes for exempt people and for a listed email" do
    person = learning_person!
    empty = AC::Context.new
    empty.stubs(:manual_emails).returns(Set.new)
    assert_not AC.passed?("human_operating_manual", person, empty)

    listed = AC::Context.new
    listed.stubs(:manual_emails).returns(Set.new([person.email.downcase]))
    assert AC.passed?("human_operating_manual", person, listed)

    person.update!(requires_human_operating_manual: false)
    assert AC.passed?("human_operating_manual", person, empty)
  end

  test "a check that raises counts as not passed" do
    person = learning_person!
    person.stubs(:forecast_person).raises(StandardError, "boom")
    assert_not AC.passed?("forecast_account", person)
  end

  test "every key has a label for the admin select" do
    assert_equal AC.keys.sort, AC.options_for_select.map(&:last).sort
    assert AC.options_for_select.all? { |label, _| label.present? }
  end
end
