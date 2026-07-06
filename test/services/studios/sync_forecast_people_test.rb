require "test_helper"

class Studios::SyncForecastPeopleTest < ActiveSupport::TestCase
  setup do
    @g3d = Studio.create!(name: "garden3d", mini_name: "g3d", studio_type: :client_services)
    @xxix = Studio.create!(name: "XXIX", mini_name: "xxix", studio_type: :client_services, accounting_prefix: "XXIX")
    # Person matched to XXIX by Forecast role name
    @role_matched = ForecastPerson.create!(forecast_id: 9001, email: "role@x.com", roles: ["XXIX"])
    # Person with no studio at all
    @unmatched = ForecastPerson.create!(forecast_id: 9002, email: "none@x.com", roles: [])
  end

  test "mirrors Studio#forecast_people into the join table" do
    Studios::SyncForecastPeople.call

    # garden3d gets everyone (Studio#forecast_people returns all people for g3d)
    g3d_ids = StudioForecastPerson.where(studio: @g3d).pluck(:forecast_person_id)
    assert_includes g3d_ids, @role_matched.id
    assert_includes g3d_ids, @unmatched.id

    xxix_ids = StudioForecastPerson.where(studio: @xxix).pluck(:forecast_person_id)
    assert_equal [@role_matched.id], xxix_ids
  end

  test "rebuild removes stale mappings" do
    StudioForecastPerson.create!(studio: @xxix, forecast_person: @unmatched)
    Studios::SyncForecastPeople.call
    refute StudioForecastPerson.where(studio: @xxix, forecast_person: @unmatched).exists?
  end
end
