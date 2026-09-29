require 'test_helper'

class StacksWeeklyShipsGraderTest < ActiveSupport::TestCase
  Grader = Stacks::WeeklyShips::Grader

  def setup
    Stacks::AI.stubs(:configured?).returns(true)
    Grader.stubs(:enabled?).returns(true)
    @tracker = ProjectTracker.new(name: "Replit Marketing Site").tap { |t| t.save!(validate: false) }
  end

  def make_doc(title: "[Replit / SC] Weekly Ship", occurred_at: 1.day.ago, chunks: ["This week we shipped things."],
               speaker: "Zach Davis")
    doc = Document.create!(
      source: :google_groups, external_id: "<#{SecureRandom.hex(6)}@mail.gmail.com>",
      title: title, occurred_at: occurred_at, content_hash: SecureRandom.hex(8),
      raw_metadata: { "group_email" => "ships@sanctuary.computer", "gmail_message_ids" => [] }
    )
    Array(chunks).each_with_index do |c, i|
      content, who = c.is_a?(Array) ? c : [c, speaker]
      doc.chunks.create!(position: i, content: content, speaker_name: who, source: :google_groups, occurred_at: occurred_at)
    end
    doc
  end

  def link(doc, tracker = @tracker, sent_at: doc.occurred_at)
    ws = WeeklyShip.new(document: doc, project_tracker: tracker, sent_at: sent_at, sent_by_name: "Zach Davis")
    ws.via_sweep = true
    ws.matched_by = :llm
    ws.save!
    ws
  end

  def scores(all = 2, **over)
    Grader::DIMENSIONS.keys.to_h { |k| [k, { "why" => "because", "score" => over.fetch(k.to_sym, all) }] }
  end

  def ai(dimensions: scores, summary: "Clear, concrete update.", suggestions: ["Name who owns the lockfile fix."])
    Stacks::AI::Result.new({ "dimensions" => dimensions, "summary" => summary, "suggestions" => suggestions }, 3000, 400)
  end

  # --- pure pieces ----------------------------------------------------------

  test "stars follow the rubric's share of available points" do
    assert_equal 5, Grader.stars_for(scores(2), has_previous: true)                       # 14/14
    assert_equal 5, Grader.stars_for(scores(2, asks: 1), has_previous: true)              # 13/14
    assert_equal 4, Grader.stars_for(scores(2, asks: 1, money: 1), has_previous: true)    # 12/14
    assert_equal 3, Grader.stars_for(scores(1), has_previous: true)                       # 7/14
    assert_equal 2, Grader.stars_for(scores(1, asks: 0, money: 0, timeline: 0), has_previous: true) # 4/14
    assert_equal 1, Grader.stars_for(scores(0, shipped: 1), has_previous: true)           # 1/14
  end

  test "continuity is not scored for a first ship" do
    # 12/12 without continuity is a five, even though the model put a 0 there
    assert_equal 5, Grader.stars_for(scores(2, continuity: 0), has_previous: false)
    assert_equal 4, Grader.stars_for(scores(2, continuity: 0), has_previous: true)
  end

  test "ship text keeps the sender's own words: drops quoted replies, the Groups footer and chunk overlap" do
    words = (1..420).map { |i| "w#{i}" }
    first = words.first(380).join(" ")
    second = words.last(80).join(" ") # the chunker repeats the last 40 words of the previous slice
    doc = make_doc(chunks: [first, second + " Thanks, Zach -- You received this message because you are subscribed", ["Client reply here", "Client"]])
    text = Grader.ship_text(doc)
    assert_equal words.join(" ") + " Thanks, Zach", text
    refute_includes text, "Client reply"

    quoted = make_doc(chunks: ["Hi Yolanda, this week we built the nav. James > On 10 Sep 2026, at 16:48, Yolanda wrote: > old stuff"])
    assert_equal "Hi Yolanda, this week we built the nav. James", Grader.ship_text(quoted)
  end

  test "the prompt carries the ship and the previous ship, and says so when there is none" do
    with_prev = Grader.build_prompt(subject: "S", sender: "Zach", sent_at: Time.zone.parse("2026-09-21"),
                                    text: "BODY", previous_text: "PREV", previous_sent_at: Time.zone.parse("2026-09-14"))
    assert_includes with_prev, "BODY"
    assert_includes with_prev, "PREV"
    assert_includes with_prev, "7 days before"
    without = Grader.build_prompt(subject: "S", sender: "Zach", sent_at: Time.zone.now, text: "BODY", previous_text: nil, previous_sent_at: nil)
    assert_includes without, "No previous ship"
  end

  # --- the run --------------------------------------------------------------

  test "grades an ungraded ship once and stamps every tracker row for that email" do
    other = ProjectTracker.new(name: "Replit Docs").tap { |t| t.save!(validate: false) }
    doc = make_doc
    a, b = link(doc), link(doc, other)
    Stacks::AI.expects(:extract).once.returns(ai(dimensions: scores(2, asks: 1, money: 1)))

    stats = Grader.run!
    assert_equal 1, stats[:graded]
    [a, b].each do |ws|
      s = ws.reload.metadata["scoring"]
      assert_equal 4, s["stars"]
      assert_equal Grader::RUBRIC_VERSION, s["rubric_version"]
      assert_equal ["Name who owns the lockfile fix."], s["suggestions"]
      assert_equal "Clear, concrete update.", s["summary"]
      assert_equal 1, s["dimensions"]["asks"]["score"]
      assert_equal "claude-haiku-4-5", s["model"]
      assert s["graded_at"].present?
    end

    Stacks::AI.expects(:extract).never
    assert_equal 0, Grader.run![:graded], "a graded ship is never re-graded"
  end

  test "a tracker linked after grading gets the email's existing grade, with no model call" do
    doc = make_doc
    link(doc)
    Stacks::AI.stubs(:extract).returns(ai)
    Grader.run!
    late = link(doc, ProjectTracker.new(name: "Late link").tap { |t| t.save!(validate: false) })
    Stacks::AI.expects(:extract).never
    stats = Grader.run!
    assert_equal 1, stats[:copied]
    assert_equal WeeklyShip.where(document: doc).first.metadata["scoring"], late.reload.metadata["scoring"]
  end

  test "grading never human-locks the ship's scan" do
    doc = make_doc
    link(doc)
    ShipScan.create!(document: doc, outcome: :linked, scanned_at: 1.day.ago, scanned_content_hash: doc.content_hash)
    Stacks::AI.stubs(:extract).returns(ai)
    Grader.run!
    refute ShipScan.find_by(document: doc).human_locked?
  end

  test "hands the grader the previous ship on the same tracker" do
    prev = make_doc(title: "Prev ship", occurred_at: 8.days.ago, chunks: ["LAST WEEK WE PROMISED X"])
    link(prev).update_columns(metadata: { "scoring" => { "stars" => 3 } })
    doc = make_doc(occurred_at: 1.day.ago)
    link(doc)
    Stacks::AI.expects(:extract).once.with { |args| args[:prompt].include?("LAST WEEK WE PROMISED X") }.returns(ai)
    Grader.run!
  end

  test "skips old ships, walled ships, and respects the per-run cap" do
    link(make_doc(occurred_at: 40.days.ago))
    walled = make_doc
    link(walled)
    walled.update_columns(excluded: Document.excludeds[:manually_excluded])
    3.times { link(make_doc) }
    Stacks::AI.expects(:extract).times(2).returns(ai)
    stats = Grader.run!(limit: 2)
    assert_equal 2, stats[:graded]
    assert_equal 0, WeeklyShip.where(document: walled).where("metadata -> 'scoring' IS NOT NULL").count
  end

  test "a model failure or a malformed grade writes nothing and is retried next night" do
    doc = make_doc
    ws = link(doc)
    Stacks::AI.stubs(:extract).raises(Stacks::AI::Error, "boom")
    assert_equal 1, Grader.run![:errored]
    assert_nil ws.reload.metadata["scoring"]

    Stacks::AI.stubs(:extract).returns(ai(suggestions: []))
    assert_equal 1, Grader.run![:errored], "no suggestions is not a grade"
    Stacks::AI.stubs(:extract).returns(ai(dimensions: scores(2, shipped: 7)))
    assert_equal 1, Grader.run![:errored], "an out-of-range score is not a grade"
    assert_nil ws.reload.metadata["scoring"]
  end

  test "more than three suggestions are trimmed to three" do
    link(make_doc)
    Stacks::AI.stubs(:extract).returns(ai(suggestions: %w[a b c d]))
    Grader.run!
    assert_equal %w[a b c], WeeklyShip.last.metadata["scoring"]["suggestions"]
  end

  test "em dashes in the feedback become commas" do
    link(make_doc)
    Stacks::AI.stubs(:extract).returns(ai(summary: "Clear — and kind.", suggestions: ["Name the date—and the owner."]))
    Grader.run!
    s = WeeklyShip.last.metadata["scoring"]
    assert_equal "Clear, and kind.", s["summary"]
    assert_equal ["Name the date, and the owner."], s["suggestions"]
  end

  test "dry run grades without writing" do
    ws = link(make_doc)
    Stacks::AI.stubs(:extract).returns(ai)
    stats = Grader.run!(dry_run: true)
    assert_equal 1, stats[:graded]
    assert_equal 1, stats[:results].size
    assert_nil ws.reload.metadata["scoring"]
  end

  test "off until WEEKLY_SHIP_GRADING=on; the dry-run preview still works" do
    Grader.unstub(:enabled?)
    ws = link(make_doc)
    Stacks::AI.stubs(:extract).returns(ai)
    with_env("WEEKLY_SHIP_GRADING" => nil) do
      stats = Grader.run!
      assert_equal 1, stats[:skipped_disabled]
      assert_equal 0, stats[:errored]
      assert_nil ws.reload.metadata["scoring"]
      assert_equal 1, Grader.run!(dry_run: true)[:graded]
    end
    with_env("WEEKLY_SHIP_GRADING" => "on") { assert_equal 1, Grader.run![:graded] }
  end

  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  test "a ship row without the metadata column (deploy before migration) has no grade, and does not crash" do
    ws = WeeklyShip.select(:id, :document_id, :project_tracker_id, :sent_at).find(link(make_doc).id)
    assert_nil ws.grade
    assert_nil ws.grade_json
  end

  test "no AI key: skips without error" do
    link(make_doc)
    Stacks::AI.stubs(:configured?).returns(false)
    Stacks::AI.expects(:extract).never
    assert_equal 1, Grader.run![:skipped_no_key]
  end
end
