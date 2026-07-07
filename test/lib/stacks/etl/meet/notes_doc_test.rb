require "test_helper"

class Stacks::Etl::Meet::NotesDocTest < ActiveSupport::TestCase
  class Host
    include Stacks::Etl::Meet::NotesDoc
  end
  def mod = Host.new

  COMBINED = <<~TXT
    # **📝 Notes**

    ## **Business Meeting**

    Invited [Alice](mailto:alice@x.co) [Bob](mailto:bob@x.co) [Room](mailto:room@resource.calendar.google.com)

    Meeting records [Transcript](https://docs.google.com/document/d/SELF_ID/edit?usp=drive_web)

    ### Summary
    We planned the sprint.

    # **📖 Transcript**

    Alice: kicking off the sprint
    Bob: sounds good to me
  TXT

  test "split_transcript splits at the first heading containing 'Transcript'" do
    notes_md, transcript_md = mod.split_transcript(COMBINED)
    assert_includes notes_md, "We planned the sprint"
    refute_includes notes_md, "kicking off the sprint"
    assert_includes transcript_md, "Alice: kicking off the sprint"
  end

  test "split_transcript returns empty transcript_md when no heading matches" do
    notes_md, transcript_md = mod.split_transcript("# Notes\n\n### Summary\nJust notes.")
    assert_includes notes_md, "Just notes."
    assert_equal "", transcript_md
  end

  test "invited_emails_from extracts lowercased emails, skipping room resources" do
    assert_equal ["alice@x.co", "bob@x.co"], mod.invited_emails_from(COMBINED)
  end

  test "notes_segments returns paragraph segments with no speaker, footer noise stripped" do
    notes_text = "### Summary\nWe planned.\n\nWe've updated the Decisions section in your doc. Check it out!"
    at = Time.utc(2026, 6, 30, 15)
    segs = mod.notes_segments(notes_text, occurred_at: at)
    assert segs.any?
    joined = segs.map { |s| s[:text] }.join(" ")
    assert_includes joined, "We planned."
    refute_includes joined, "We've updated the Decisions"
    assert_nil segs.first[:speaker_name]
    assert_equal at, segs.first[:started_at]
  end
end
