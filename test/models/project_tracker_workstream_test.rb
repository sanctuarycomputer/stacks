require "test_helper"

class ProjectTrackerWorkstreamTest < ActiveSupport::TestCase
  def tracker
    ProjectTracker.provision!(name: "Qualitate", msa_url: "https://e.com/m", sow_url: "https://e.com/s").first
  end

  # A fake Stacks::Forecast whose create_project ALSO creates the local mirror row
  # (real create_project mirrors; the stub must too, so the join's belongs_to resolves).
  def fake_forecast(project_forecast_id:, client:)
    fc = Object.new
    fc.define_singleton_method(:find_or_create_client!) { |_name| client }
    fc.define_singleton_method(:create_project) do |client_id:, name:, code:, tags: [], notes: ""|
      ForecastProject.new(forecast_id: project_forecast_id, client_id: client_id, name: name, code: code, tags: tags).save!(validate: false)
      { "id" => project_forecast_id, "code" => code, "tags" => tags }
    end
    fc
  end

  test "first workstream find-or-creates the client and attaches a coded project" do
    client = ForecastClient.new(forecast_id: 42, name: "Qualitate").tap { |c| c.save!(validate: false) }
    t = tracker
    ws = t.add_workstream!(name: "Design", code: "QUAL-1", rate: 450, client_name: "Qualitate",
                           forecast_client: fake_forecast(project_forecast_id: 5001, client: client))
    assert_kind_of ProjectTrackerForecastProject, ws
    assert_equal 5001, ws.forecast_project_id
    assert_equal [5001], t.reload.forecast_projects.map(&:forecast_id)
    assert_equal ["450p/h"], ForecastProject.find_by(forecast_id: 5001).tags
  end

  test "subsequent workstream reuses the tracker's existing client" do
    client = ForecastClient.new(forecast_id: 42, name: "Qualitate").tap { |c| c.save!(validate: false) }
    t = tracker
    t.add_workstream!(name: "A", code: "QUAL-1", client_name: "Qualitate",
                      forecast_client: fake_forecast(project_forecast_id: 5001, client: client))
    # second add: no client_name; must reuse client 42 via derived_client
    fc2 = Object.new
    fc2.define_singleton_method(:create_project) do |client_id:, name:, code:, tags: [], notes: ""|
      raise "wrong client" unless client_id == 42
      ForecastProject.new(forecast_id: 5002, client_id: client_id, name: name, code: code, tags: tags).save!(validate: false)
      { "id" => 5002 }
    end
    ws2 = t.reload.add_workstream!(name: "B", code: "QUAL-2", forecast_client: fc2)
    assert_equal 5002, ws2.forecast_project_id
  end

  test "raises when the first workstream has no client to resolve" do
    t = tracker
    assert_raises(ActiveRecord::RecordInvalid) { t.add_workstream!(name: "X", code: "C", forecast_client: Object.new) }
  end

  test "raises when the code is blank, without calling create_project" do
    client = ForecastClient.new(forecast_id: 42, name: "Qualitate").tap { |c| c.save!(validate: false) }
    t = tracker
    fc = Object.new
    fc.define_singleton_method(:find_or_create_client!) { |_name| client }
    fc.define_singleton_method(:create_project) { |**_kwargs| flunk "create_project should not be called when the code is blank" }
    assert_raises(ActiveRecord::RecordInvalid) do
      t.add_workstream!(name: "X", code: "", client_name: "Qualitate", forecast_client: fc)
    end
  end

  test "raises when the code is blank and a new client_name is given, without calling find_or_create_client!" do
    t = tracker
    fc = Object.new
    fc.define_singleton_method(:find_or_create_client!) { |_name| flunk "find_or_create_client! should not be called when the code is blank" }
    fc.define_singleton_method(:create_project) { |**_kwargs| flunk "create_project should not be called when the code is blank" }
    assert_raises(ActiveRecord::RecordInvalid) do
      t.add_workstream!(name: "X", code: "", client_name: "Brand New Client", forecast_client: fc)
    end
  end

  test "raises when the code is already attached to another tracker, without calling create_project" do
    client = ForecastClient.new(forecast_id: 42, name: "Qualitate").tap { |c| c.save!(validate: false) }
    tracker_a = tracker
    ForecastProject.new(forecast_id: 6001, client_id: 42, name: "Existing", code: "DUP-1", tags: []).save!(validate: false)
    tracker_a.project_tracker_forecast_projects.create!(forecast_project_id: 6001)

    tracker_b = tracker
    fc = Object.new
    fc.define_singleton_method(:find_or_create_client!) { |_name| client }
    fc.define_singleton_method(:create_project) { |**_kwargs| flunk "create_project should not be called for a colliding code" }
    assert_raises(ActiveRecord::RecordInvalid) do
      tracker_b.add_workstream!(name: "Y", code: "DUP-1", client_name: "Qualitate", forecast_client: fc)
    end
  end
end
