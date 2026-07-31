require "test_helper"

# Covers the no-op-skip fix for the Forecast sync: an unconditional upsert_all rewrote
# every overlapping record on every sync window, churning forecast_assignments to ~71M
# updates / 26GB of bloat for ~46k live rows. upsert_changed! now writes only new/changed
# rows while still reporting every seen id so prune-by-absence stays correct.
class StacksForecastTest < ActiveSupport::TestCase
  def row(forecast_id, updated_at, allocation: 100)
    {
      forecast_id: forecast_id, start_date: "2024-01-01", end_date: "2024-01-31",
      allocation: allocation, notes: nil, updated_at: updated_at, updated_by_id: 1,
      project_id: 1, person_id: 1, placeholder_id: nil,
      repeated_assignment_set_id: nil, active_on_days_off: false, data: { "id" => forecast_id },
    }
  end

  # allocate skips initialize (which needs Forecast API config); we only exercise the helper.
  def forecast = Stacks::Forecast.allocate

  test "first sync upserts all rows and returns every seen id" do
    ids = forecast.send(:upsert_changed!, ForecastAssignment,
                        [row(1, "2024-01-01T00:00:00Z"), row(2, "2024-01-02T00:00:00Z")])
    assert_equal [1, 2], ids
    assert_equal 2, ForecastAssignment.where(forecast_id: [1, 2]).count
  end

  test "re-syncing unchanged rows skips the write entirely but still reports them as seen" do
    data = [row(1, "2024-01-01T00:00:00Z"), row(2, "2024-01-02T00:00:00Z")]
    forecast.send(:upsert_changed!, ForecastAssignment, data)

    ForecastAssignment.expects(:upsert_all).never # the bug: this used to fire every time
    ids = forecast.send(:upsert_changed!, ForecastAssignment, data)
    assert_equal [1, 2], ids, "unchanged-but-present rows must still count as seen so prune won't delete them"
  end

  test "only rows whose Forecast updated_at advanced (or are new) are rewritten" do
    forecast.send(:upsert_changed!, ForecastAssignment,
                  [row(1, "2024-01-01T00:00:00Z", allocation: 100), row(2, "2024-01-02T00:00:00Z", allocation: 100)])

    # row 1 unchanged; row 2's updated_at advances with a new allocation; row 3 is new.
    next_data = [
      row(1, "2024-01-01T00:00:00Z", allocation: 100),
      row(2, "2024-02-02T00:00:00Z", allocation: 50),
      row(3, "2024-03-01T00:00:00Z", allocation: 25),
    ]
    captured = nil
    ForecastAssignment.stubs(:upsert_all).with { |rows, **| captured = rows.map { |r| r[:forecast_id] }; true }
    ids = forecast.send(:upsert_changed!, ForecastAssignment, next_data)

    assert_equal [2, 3], captured, "only the changed + new rows are sent to upsert_all"
    assert_equal [1, 2, 3], ids, "all seen ids are still returned for pruning"
  end

  test "a changed row's new values actually land in the database" do
    forecast.send(:upsert_changed!, ForecastAssignment, [row(1, "2024-01-01T00:00:00Z", allocation: 100)])
    forecast.send(:upsert_changed!, ForecastAssignment, [row(1, "2024-02-01T00:00:00Z", allocation: 42)])
    assert_equal 42, ForecastAssignment.find_by(forecast_id: 1).allocation
  end

  def build_forecast_client
    fc = Stacks::Forecast.allocate
    fc.instance_variable_set(:@headers, { "Authorization": "Bearer test" })
    fc
  end

  test "create_assignment POSTs the assignment envelope and returns the assignment hash" do
    fc = build_forecast_client
    response = mock("response")
    response.stubs(:success?).returns(true)
    response.stubs(:parsed_response).returns({ "assignment" => { "id" => 42, "allocation" => 900 } })

    posted = {}
    Stacks::Forecast.expects(:post).once.with do |path, opts|
      posted[:path] = path
      posted[:body] = JSON.parse(opts[:body])
      true
    end.returns(response)

    result = fc.create_assignment(
      project_id: 5039734, person_id: 324711,
      start_date: Date.new(2035, 6, 1), end_date: Date.new(2035, 6, 1),
      allocation: 900, notes: "hi", active_on_days_off: false,
    )

    assert_equal 42, result["id"]
    assert_equal "/assignments", posted[:path]
    assert_equal 5039734, posted[:body]["assignment"]["project_id"]
    assert_equal "2035-06-01", posted[:body]["assignment"]["start_date"]
    assert_equal 900, posted[:body]["assignment"]["allocation"]
  end

  test "create_assignment raises on failure" do
    fc = build_forecast_client
    response = mock("response")
    response.stubs(:success?).returns(false)
    response.stubs(:code).returns(422)
    response.stubs(:body).returns("nope")
    Stacks::Forecast.stubs(:post).returns(response)

    assert_raises(RuntimeError) do
      fc.create_assignment(project_id: 1, person_id: 2, start_date: Date.today, end_date: Date.today, allocation: 900)
    end
  end

  test "create_project POSTs the project envelope, returns it, and upserts the local mirror" do
    fc = build_forecast_client
    response = mock("resp"); response.stubs(:success?).returns(true)
    response.stubs(:parsed_response).returns({ "project" => {
      "id" => 777, "name" => "Qualitate Retainer", "code" => "QUAL-1", "client_id" => 42,
      "tags" => ["450p/h"], "archived" => false, "updated_at" => "2026-07-31T00:00:00Z",
    } })
    posted = {}
    Stacks::Forecast.expects(:post).once.with do |path, opts|
      posted[:path] = path; posted[:body] = JSON.parse(opts[:body]); true
    end.returns(response)

    result = fc.create_project(client_id: 42, name: "Qualitate Retainer", code: "QUAL-1", tags: ["450p/h"])

    assert_equal 777, result["id"]
    assert_equal "/projects", posted[:path]
    assert_equal 42, posted[:body]["project"]["client_id"]
    assert_equal ["450p/h"], posted[:body]["project"]["tags"]
    fp = ForecastProject.find_by(forecast_id: 777)
    assert_equal "QUAL-1", fp.code
    assert_equal ["450p/h"], fp.tags
  end

  test "update_project PUTs partial attrs and re-upserts the mirror" do
    fc = build_forecast_client
    response = mock("resp"); response.stubs(:success?).returns(true)
    response.stubs(:parsed_response).returns({ "project" => {
      "id" => 777, "name" => "Q", "code" => "QUAL-1", "client_id" => 42, "tags" => ["450p/h","300p/h"],
    } })
    Stacks::Forecast.expects(:put).once.with do |path, opts|
      path == "/projects/777" && JSON.parse(opts[:body])["project"]["tags"] == ["450p/h","300p/h"]
    end.returns(response)

    fc.update_project(777, tags: ["450p/h", "300p/h"])
    assert_equal ["450p/h","300p/h"], ForecastProject.find_by(forecast_id: 777).tags
  end

  test "rate_tag normalizes numbers and $ prefixes" do
    assert_equal "450p/h", Stacks::Forecast.rate_tag(450)
    assert_equal "450p/h", Stacks::Forecast.rate_tag("$450p/h")
    assert_equal "99.75p/h", Stacks::Forecast.rate_tag(99.75)
  end

  test "add_project_rate! appends the tag without clobbering others, asserting the sent payload" do
    ForecastProject.new(forecast_id: 900, code: "C", name: "N", client_id: 1, tags: ["300p/h"]).save!(validate: false)
    fc = build_forecast_client
    resp = mock("r"); resp.stubs(:success?).returns(true)
    resp.stubs(:parsed_response).returns({ "project" => { "id" => 900, "tags" => ["300p/h","450p/h"], "code"=>"C","name"=>"N","client_id"=>1 } })
    # Assert the tags array actually SENT to Forecast — this proves the computation, not the stub.
    Stacks::Forecast.expects(:put).once.with do |path, opts|
      path == "/projects/900" && JSON.parse(opts[:body])["project"]["tags"] == ["300p/h","450p/h"]
    end.returns(resp)

    fc.add_project_rate!(900, 450)
    assert_equal ["300p/h","450p/h"], ForecastProject.find_by(forecast_id: 900).tags
  end

  test "add_project_rate! is idempotent — no write when the rate is already present" do
    ForecastProject.new(forecast_id: 902, code: "C", name: "N", client_id: 1, tags: ["450p/h"]).save!(validate: false)
    fc = build_forecast_client
    Stacks::Forecast.expects(:put).never   # already present → no HTTP write at all
    fc.add_project_rate!(902, 450)
    assert_equal ["450p/h"], ForecastProject.find_by(forecast_id: 902).tags
  end

  test "remove_project_rate! sends the tags array with only that rate dropped" do
    ForecastProject.new(forecast_id: 901, code: "C", name: "N", client_id: 1, tags: ["300p/h","450p/h"]).save!(validate: false)
    fc = build_forecast_client
    resp = mock("r"); resp.stubs(:success?).returns(true)
    resp.stubs(:parsed_response).returns({ "project" => { "id" => 901, "tags" => ["300p/h"], "code"=>"C","name"=>"N","client_id"=>1 } })
    Stacks::Forecast.expects(:put).once.with do |path, opts|
      path == "/projects/901" && JSON.parse(opts[:body])["project"]["tags"] == ["300p/h"]
    end.returns(resp)

    fc.remove_project_rate!(901, 450)
    assert_equal ["300p/h"], ForecastProject.find_by(forecast_id: 901).tags
  end

  test "delete_assignment DELETEs by id and treats 404 as already-gone" do
    fc = build_forecast_client

    ok = mock("ok"); ok.stubs(:success?).returns(true)
    Stacks::Forecast.expects(:delete).once.with("/assignments/99", has_entry(:headers, instance_of(Hash))).returns(ok)
    assert_equal true, fc.delete_assignment(99)

    gone = mock("gone"); gone.stubs(:success?).returns(false); gone.stubs(:code).returns(404)
    Stacks::Forecast.expects(:delete).once.returns(gone)
    assert_equal true, fc.delete_assignment(1234)
  end
end
