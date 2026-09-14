require "test_helper"

class Resourcing::RunnPersonResolverTest < ActiveSupport::TestCase
  def contributor_for(email: "ada@example.com")
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: email, data: {})
    Contributor.create!(forecast_person: fp)
  end

  test "matches a contributor's forecast_person email against get_people and returns that id" do
    c = contributor_for(email: "ada@example.com")
    runn = mock("runn")
    runn.stubs(:get_people).returns([
      { "id" => 10, "email" => "ada@example.com", "isArchived" => false },
    ])
    assert_equal 10, Resourcing::RunnPersonResolver.new(runn).runn_person_id_for(c)
  end

  test "no match in get_people returns nil" do
    c = contributor_for(email: "nomatch@example.com")
    runn = mock("runn")
    runn.stubs(:get_people).returns([
      { "id" => 10, "email" => "ada@example.com", "isArchived" => false },
    ])
    assert_nil Resourcing::RunnPersonResolver.new(runn).runn_person_id_for(c)
  end

  test "an archived match is not resolved" do
    c = contributor_for(email: "ada@example.com")
    runn = mock("runn")
    runn.stubs(:get_people).returns([
      { "id" => 10, "email" => "ada@example.com", "isArchived" => true },
    ])
    assert_nil Resourcing::RunnPersonResolver.new(runn).runn_person_id_for(c)
  end

  test "two active non-archived matches for the same email is unresolved" do
    c = contributor_for(email: "ada@example.com")
    runn = mock("runn")
    runn.stubs(:get_people).returns([
      { "id" => 10, "email" => "ada@example.com", "isArchived" => false },
      { "id" => 11, "email" => "ada@example.com", "isArchived" => false },
    ])
    assert_nil Resourcing::RunnPersonResolver.new(runn).runn_person_id_for(c)
  end

  test "a blank email returns nil without calling get_people" do
    fp = ForecastPerson.create!(forecast_id: rand(1..2_000_000_000), email: "", data: {})
    c = Contributor.create!(forecast_person: fp)
    runn = mock("runn")
    runn.expects(:get_people).never
    assert_nil Resourcing::RunnPersonResolver.new(runn).runn_person_id_for(c)
  end
end
