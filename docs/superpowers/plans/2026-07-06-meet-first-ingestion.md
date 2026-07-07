# Meet-First Ingestion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive daily Meet ingestion from the Meet API (meeting-first: structured transcripts + notes via `docsDestination`), demoting brittle markdown transcript parsing to the historical backfill path only, behind a canary that fails loud on a Google format change.

**Architecture:** A new `NotesDoc` shared module extracts notes parsing out of `GeminiNotesSource` so both `GeminiNotesSource` and `MeetApiSource` can use it. `GeminiNotesSource` gains a `parse_transcript:` flag: daily mode (`false`) skips transcript-bearing docs and emits notes-only; backfill mode (`true`) retains the combined-markdown parser with a canary. `MeetApiSource` adds a Drive service and emits a `gemini_notes` record per conference record that has a `docsDestination`, best-effort. The flag threads through `Connector` → `sweep_all_users!` → rake.

**Tech Stack:** Ruby 3.1 / Rails 6.1, Minitest + mocha (no WebMock), PostgreSQL + pgvector (`neighbor`), local ONNX embeddings.

## Global Constraints

- Privacy wall: transcript classified by ACTUAL attendance (API participant count; backfill distinct speakers), never invited count; notes inherit the transcript's `excluded`/`excluded_reason` verbatim via `for_drive_doc(transcript_doc_id)` at ingest, else fall back to invited count (notes-only).
- Progressive enhancement: DriveSource/MeetApiSource transcript ingestion behavior preserved; the API notes emission and the `parse_transcript` split are additive.
- One transcript per meeting via `for_drive_doc` reverse-dedup; two Documents (`meet` + `gemini_notes`) share one Meeting.
- Tests Minitest + mocha (stub Google services via mocha, no WebMock). CI uses in-dyno Postgres so embedding-touching tests guard with `skip_without_pgvector`; schema.rb hand-manages pgvector omissions.
- Best-effort `docsDestination` export: skip notes on failure, never abort the transcript.

---

### Task 1: Extract `Stacks::Etl::Meet::NotesDoc` shared module

Move the reusable notes-parsing out of `GeminiNotesSource` into a new module that both `GeminiNotesSource` and `MeetApiSource` can include. Pure extraction: existing tests must still pass after the rename.

**Files:**
- Create: `lib/stacks/etl/meet/notes_doc.rb`
- Modify: `lib/stacks/etl/meet/gemini_notes_source.rb` (include NotesDoc, remove moved methods, rename call sites)
- Create: `test/lib/stacks/etl/meet/notes_doc_test.rb`
- Modify: `test/lib/stacks/etl/meet/gemini_notes_source_test.rb` (rename `body_segments` → `notes_segments`)

**Interfaces:**
- Produces: module `Stacks::Etl::Meet::NotesDoc` with:
  - `TRANSCRIPT_HEADING` constant (`/^\#{1,2}\s+.*Transcript.*$/i`)
  - `split_transcript(text) -> [notes_md, transcript_md]` (transcript_md = "" when no heading)
  - `invited_emails_from(text) -> Array<String>` (lowercased, no room resources)
  - `notes_segments(markdown, occurred_at:) -> Array<Hash>` (footer-stripped paragraph segments, `speaker_name: nil`)
- Consumed by: `GeminiNotesSource` (include, replaces moved methods), `MeetApiSource` (Task 4)

- [ ] **Step 1: Write the failing test**

Create `test/lib/stacks/etl/meet/notes_doc_test.rb`:
```ruby
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/notes_doc_test.rb`
Expected: FAIL — `uninitialized constant Stacks::Etl::Meet::NotesDoc`.

- [ ] **Step 3: Create the NotesDoc module**

Create `lib/stacks/etl/meet/notes_doc.rb`:
```ruby
module Stacks
  module Etl
    module Meet
      # Shared notes-parsing helpers for Google Meet "Notes by Gemini" docs, included
      # by both GeminiNotesSource (Drive scan) and MeetApiSource (docsDestination export).
      # Owns the split point, the invited-email extractor, and the notes-body segmenter.
      module NotesDoc
        # First markdown heading whose text contains "Transcript" — tolerant of the 📖
        # emoji so a future Google change doesn't break it. The inline "Meeting records
        # [Transcript](…)" link is NOT a heading and is not matched.
        TRANSCRIPT_HEADING = /^\#{1,2}\s+.*Transcript.*$/i

        # Split a combined doc into [notes_body_markdown, transcript_markdown]. Everything
        # from the transcript heading onward is the transcript; everything before is the
        # notes body. Returns transcript_md = "" when no transcript heading is present.
        def split_transcript(text)
          s = text.to_s
          if (m = s.match(TRANSCRIPT_HEADING))
            [s[0...m.begin(0)], s[m.begin(0)..]]
          else
            [s, ""]
          end
        end

        # Emails only appear as mailto: links, primarily in the "Invited" block.
        def invited_emails_from(text)
          text.to_s.scan(/mailto:([^)\s]+)/).flatten.map { |e| e.downcase }
              .reject { |e| e.end_with?("resource.calendar.google.com") }.uniq
        end

        # Convert the notes portion (already split from the transcript) into paragraph
        # segments for the chunker. Strips trailing Gemini feedback/footer noise.
        # speaker_name is nil — notes are unattributed prose, not transcribed speech.
        def notes_segments(markdown, occurred_at:)
          cleaned = markdown.to_s
                            .gsub(/We['']ve updated the Decisions section.*\z/m, "")
                            .gsub(/Let us know what you think.*\z/m, "")
                            .gsub(/You should review Gemini['']s notes.*\z/m, "")
          cleaned.split(/\n{2,}/).map(&:strip).reject(&:empty?).map do |para|
            { speaker_name: nil, speaker_email: nil, text: para, started_at: occurred_at, ended_at: nil }
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Update `GeminiNotesSource` to include `NotesDoc` and remove the moved methods**

In `lib/stacks/etl/meet/gemini_notes_source.rb`:

1. Add `include NotesDoc` after `include TranscriptSegments` (line 7):
```ruby
      class GeminiNotesSource
        include DriveDoc
        include TranscriptSegments
        include NotesDoc
```

2. Remove the three methods that are now in `NotesDoc` — delete the entire bodies of `invited_emails_from`, `split_transcript` (and its `TRANSCRIPT_HEADING` constant), and `body_segments`. Keep `transcript_doc_id_from`, `combined_format?`, and `transcript_speaker_text`.

3. In `note_record`, rename the `body_segments` call to `notes_segments`:
```ruby
        def note_record(file, notes_md, full_text)
          title = clean_title(file.name)
          occurred_at = coerce(file.created_time)
          transcript_id = transcript_doc_id_from(full_text)
          emails = invited_emails_from(full_text)
          segments = notes_segments(notes_md, occurred_at: occurred_at)
          {
            source: :gemini_notes,
            external_id: file.id,
            title: title,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: occurred_at,
            content_hash: Digest::SHA256.hexdigest(notes_md.to_s),
            contacts: emails.map { |e| { email: e, name: nil, role: "attendee" } },
            segments: segments,
            transcript_doc_id: transcript_id,
            participant_count: emails.size,
            raw_metadata: { "gemini_notes_doc_id" => file.id, "transcript_doc_id" => transcript_id },
            build_source_record: ->(doc) { build_meeting(doc, file, title, occurred_at, transcript_id) }
          }
        end
```

- [ ] **Step 5: Update the GeminiNotesSource test to rename the body_segments call**

In `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`, find the test "body segments carry the notes text with the meeting time and no speaker" and rename the call:
```ruby
  test "body segments carry the notes text with the meeting time and no speaker" do
    at = Time.utc(2026, 6, 30, 15)
    segs = src.send(:notes_segments, SAMPLE, occurred_at: at)
    assert segs.any?
    joined = segs.map { |s| s[:text] }.join(" ")
    assert_includes joined, "ship the gateway redesign"
    assert_includes joined, "Finish Slides"
    assert_nil segs.first[:speaker_name]
    assert_equal at, segs.first[:started_at]
  end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/notes_doc_test.rb test/lib/stacks/etl/meet/gemini_notes_source_test.rb`
Expected: PASS — all NotesDoc tests plus all existing GeminiNotesSource tests (including combined-format, reverse-dedup, bold-format tests).

- [ ] **Step 7: Commit**

```bash
git add lib/stacks/etl/meet/notes_doc.rb lib/stacks/etl/meet/gemini_notes_source.rb \
        test/lib/stacks/etl/meet/notes_doc_test.rb test/lib/stacks/etl/meet/gemini_notes_source_test.rb
git commit -m "Extract NotesDoc shared module (split_transcript, invited_emails_from, notes_segments)"
```

---

### Task 2: `GeminiNotesSource` `parse_transcript:` flag — daily notes-only vs backfill

Add a `parse_transcript:` kwarg (default `false`) to `GeminiNotesSource`. Daily mode skips files that already have a transcript Document and never emits a `:meet` record. Backfill mode retains the current combined-doc behavior.

**Files:**
- Modify: `lib/stacks/etl/meet/gemini_notes_source.rb`
- Modify: `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`

**Interfaces:**
- Consumes: `Document.for_drive_doc(file.id).exists?` (transcript existence check before export)
- Produces: `GeminiNotesSource.new(email, since:, parse_transcript: false)` — daily behavior; `parse_transcript: true` — current combined behavior

- [ ] **Step 1: Update existing combined-format tests to use `parse_transcript: true`**

In `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`, for each test that uses `stub_drive_returning` or constructs a `GeminiNotesSource` with a combined-format doc, add `parse_transcript: true`. The affected tests are:

"a combined doc yields a meet transcript record then a gemini_notes record":
```ruby
  test "a combined doc yields a meet transcript record then a gemini_notes record, both for the same file" do
    stub_drive_returning(COMBINED)
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1), parse_transcript: true).each_meeting { |r| out << r }
    # ... assertions unchanged ...
  end
```

"a combined doc whose transcript section has no speaker lines yields notes-only":
```ruby
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1), parse_transcript: true).each_meeting { |r| out << r }
```

"the split transcript defers to an already-ingested transcript Document (reverse dedup)":
```ruby
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1), parse_transcript: true).each_meeting { |r| out << r }
```

"combined transcript head-count uses ACTUAL speakers":
```ruby
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1), parse_transcript: true).each_meeting { |r| out << r }
```

"combined transcript with BOLD markdown speaker turns parses speakers":
```ruby
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1), parse_transcript: true).each_meeting { |r| out << r }
```

- [ ] **Step 2: Write new daily-mode tests**

Add to `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`:
```ruby
  test "daily mode (parse_transcript: false) emits notes-only for a doc with no transcript Document" do
    stub_drive_returning(COMBINED)
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |r| out << r }
    assert_equal [:gemini_notes], out.map { |r| r[:source] }, "daily mode must never emit a :meet record"
    assert_equal 1, out.size
    # Notes body must NOT include transcript dialogue
    joined = out.first[:segments].map { |s| s[:text] }.join(" ")
    refute_includes joined, "kicking off the sprint"
  end

  test "daily mode skips a file whose drive id already has a transcript Document (pre-export skip)" do
    # A transcript Document already exists for SELF_ID (e.g. from MeetApiSource raw_metadata).
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/skip")
    Document.create!(source: :meet, external_id: "conferenceRecords/skip", source_record: m,
                     raw_metadata: { "drive_doc_id" => "SELF_ID" })

    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [combined_file], next_page_token: nil))
    svc.expects(:export_file).never  # must NOT export — the skip fires before the export
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |r| out << r }
    assert_empty out, "daily mode must skip a file that already has a transcript Document"
  end

  test "daily mode never yields a :meet record even for a combined-format doc" do
    stub_drive_returning(COMBINED)
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |r| out << r }
    assert out.none? { |r| r[:source] == :meet }, "daily mode must NEVER yield a :meet record"
  end
```

- [ ] **Step 3: Run tests to verify failures**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb`
Expected: FAIL — the combined-format tests now pass `parse_transcript: true` but the initializer doesn't accept it; the daily-mode tests fail because no skip logic exists.

- [ ] **Step 4: Implement the `parse_transcript:` flag**

In `lib/stacks/etl/meet/gemini_notes_source.rb`, update `initialize`:
```ruby
        def initialize(user_email, since:, until_time: nil, parse_transcript: false)
          @user_email = user_email
          @since = coerce(since)
          @until_time = coerce(until_time)
          @parse_transcript = parse_transcript
          @service = Auth.drive_service(sub: user_email)
        end
```

Update `each_meeting` to add the pre-export skip check in daily mode:
```ruby
        def each_meeting
          page = nil
          loop do
            q = "#{QUERY} and createdTime > '#{@since.utc.iso8601}'"
            q += " and createdTime < '#{@until_time.utc.iso8601}'" if @until_time
            resp = @service.list_files(q: q, fields: "nextPageToken, files(id,name,createdTime)", page_token: page)
            Array(resp.files).each do |f|
              # Daily mode: skip without exporting if a transcript Document already covers this file.
              # MeetApiSource (which runs first in sync_all) stores drive_doc_id in raw_metadata,
              # so for_drive_doc matches it. The export is expensive — skip before it.
              next if !@parse_transcript && Document.for_drive_doc(f.id).exists?
              records_for(f).each { |r| yield r }
            end
            page = resp.next_page_token
            break unless page
          end
        end
```

Update `records_for` to branch on `@parse_transcript`:
```ruby
        def records_for(file)
          text = @service.export_file(file.id, "text/markdown")
          unless @parse_transcript
            # Daily mode: emit notes-only from the notes portion. Use split_transcript so
            # a combined-format doc that slipped past the skip check doesn't pollute the
            # notes body with transcript text. Never call parse_segments / transcript_record.
            notes_md = split_transcript(text).first
            return [note_record(file, notes_md, text)]
          end
          # Backfill mode: full combined-doc handling (transcript-from-markdown + notes).
          if combined_format?(text, file.id)
            notes_md, transcript_md = split_transcript(text)
            segments = parse_segments(transcript_speaker_text(transcript_md)).each { |s| s[:started_at] = coerce(file.created_time) }
            if segments.any?
              tx = transcript_record(file, text, transcript_md, segments)
              [tx, note_record(file, notes_md, text)].compact
            else
              [note_record(file, notes_md, text)]
            end
          else
            [normalize(file, exported: text)]
          end
        end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb`
Expected: PASS — all existing combined-format tests pass with `parse_transcript: true`; all new daily-mode tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/stacks/etl/meet/gemini_notes_source.rb test/lib/stacks/etl/meet/gemini_notes_source_test.rb
git commit -m "GeminiNotesSource: add parse_transcript: flag — daily notes-only vs backfill combined parsing"
```

---

### Task 3: Canary in backfill mode

When `parse_transcript: true` and a doc's transcript section is present with substantial content (>200 chars) but `parse_segments` yields 0 speakers, log an error. A genuinely empty section does not log. Sentry captures error logs; never raise or abort the sweep.

**Files:**
- Modify: `lib/stacks/etl/meet/gemini_notes_source.rb`
- Modify: `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`

**Interfaces:**
- Consumes: `records_for(file)` backfill branch from Task 2
- Produces: `Rails.logger.error("[gemini_notes] transcript present but 0 speakers parsed — possible Meet format change: #{file.id}")` when threshold exceeded with 0 speakers

- [ ] **Step 1: Write the failing tests**

Add to `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`:
```ruby
  test "canary: substantial transcript section with 0 speakers logs an error (possible format change)" do
    # Build a combined doc whose transcript section is >200 chars but has NO speaker lines.
    no_speaker_tx = "# **📝 Notes**\n\n## **Business Meeting**\n\nInvited [A](mailto:a@x.co) [B](mailto:b@x.co) [C](mailto:c@x.co)\n\nMeeting records [Transcript](https://docs.google.com/document/d/SELF_ID/edit)\n\n### Summary\nWe planned the sprint.\n\n# **📖 Transcript**\n\n" \
                    "This is some transcript content that does not follow the speaker format at all. " \
                    "It has multiple lines but none of them match the Name: text speaker pattern. " \
                    "This is intentionally malformed to test the canary detection path in backfill mode.\n"
    stub_drive_returning(no_speaker_tx)
    Rails.logger.expects(:error).with { |msg| msg.include?("[gemini_notes]") && msg.include?("SELF_ID") }.once
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1), parse_transcript: true).each_meeting { |r| out << r }
    # Still emits notes (does not abort)
    assert_equal [:gemini_notes], out.map { |r| r[:source] }
  end

  test "canary: tiny/empty transcript section does NOT log (Transcription ended message)" do
    empty_tx = "# **📝 Notes**\n\n## **Quick Sync**\n\nInvited [A](mailto:a@x.co)\n\nMeeting records [Transcript](https://docs.google.com/document/d/SELF_ID/edit)\n\n### Summary\nShort.\n\n# **📖 Transcript**\n\n### Transcription ended after 00:01:30\n"
    stub_drive_returning(empty_tx)
    Rails.logger.expects(:error).never
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1), parse_transcript: true).each_meeting { |r| out << r }
    assert_equal [:gemini_notes], out.map { |r| r[:source] }
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb -n /canary/`
Expected: FAIL — the `expects(:error).once` test fails (no error logged); the `expects(:error).never` test passes accidentally but both need to pass together.

- [ ] **Step 3: Implement the canary check**

In `lib/stacks/etl/meet/gemini_notes_source.rb`, update the backfill branch of `records_for` to add the canary after `split_transcript` and `parse_segments`:
```ruby
          # Backfill mode: full combined-doc handling (transcript-from-markdown + notes).
          if combined_format?(text, file.id)
            notes_md, transcript_md = split_transcript(text)
            stripped = transcript_speaker_text(transcript_md)
            segments = parse_segments(stripped).each { |s| s[:started_at] = coerce(file.created_time) }
            # Canary: a substantial transcript section (> 200 chars) that yields 0 speakers
            # means Google likely changed the markdown format. Log loudly — Sentry captures
            # error logs — but do NOT raise or abort; still emit notes.
            if transcript_md.length > 200 && segments.empty?
              Rails.logger.error("[gemini_notes] transcript present but 0 speakers parsed — possible Meet format change: #{file.id}")
            end
            if segments.any?
              tx = transcript_record(file, text, transcript_md, segments)
              [tx, note_record(file, notes_md, text)].compact
            else
              [note_record(file, notes_md, text)]
            end
          else
            [normalize(file, exported: text)]
          end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb`
Expected: PASS — all GeminiNotesSource tests including both canary tests.

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/meet/gemini_notes_source.rb test/lib/stacks/etl/meet/gemini_notes_source_test.rb
git commit -m "GeminiNotesSource: canary in backfill mode — log error when transcript section has 0 speakers"
```

---

### Task 4: `MeetApiSource` emits notes via `docsDestination`

`MeetApiSource` adds a Drive service and `include NotesDoc`. For each conference record that has a `drive_doc_id` (docsDestination), after emitting the transcript record it also emits a `gemini_notes` notes record — best-effort (export failure skips notes, never aborts transcript). Refactor `normalize` → `records_for` so `each_meeting` yields from an array.

**Files:**
- Modify: `lib/stacks/etl/meet/meet_api_source.rb`
- Modify: `test/lib/stacks/etl/meet/meet_api_source_test.rb`

**Interfaces:**
- Consumes: `NotesDoc#split_transcript`, `NotesDoc#invited_emails_from`, `NotesDoc#notes_segments`; `DriveDoc#coerce`; `Document.for_drive_doc` (ingest-time join in `build_source_record`)
- Produces: `each_meeting` yields individual records from `records_for(cr) -> Array` — `[transcript_hash]`, `[transcript_hash, notes_hash]`, or `[]` (no transcript yet). Notes hash: `source: :gemini_notes`, `external_id: drive_doc_id`, `transcript_doc_id: drive_doc_id`.

- [ ] **Step 1: Update existing tests to stub `Auth.drive_service`**

In `test/lib/stacks/etl/meet/meet_api_source_test.rb`, add an `Auth.drive_service` stub to **all 5 existing tests** so the new `initialize` doesn't fail. **Stub `export_file` to RAISE `StandardError` uniformly** — several existing tests DO carry a `docsDestination` (e.g. the Drive-doc dedup tests), so the new code will call `export_file` on them; making it raise means the notes record is skipped via the best-effort rescue and every existing single-record assertion still holds. Do NOT use a bare `mock('drive')` "never called" stub — a real invocation on an unstubbed mock raises a `Mocha::ExpectationError` that `rescue StandardError` may not catch.

Add after each test's `Auth.stubs(:meet_service).returns(svc)` line (adapt the local `svc` name to each test):
```ruby
    drive_svc = mock('drive')
    drive_svc.stubs(:export_file).raises(StandardError, "stubbed: no notes in this test")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(drive_svc)
```
This is uniform across all 5 existing tests. (If any existing test asserts on a specific yielded array size, it stays correct because notes are always skipped here.)

- [ ] **Step 2: Write new MeetApiSource notes tests**

Add to `test/lib/stacks/etl/meet/meet_api_source_test.rb`:
```ruby
  def meet_svc_for(cr, transcript, entry, participants)
    svc = mock('svc')
    svc.stubs(:list_conference_records).returns(OpenStruct.new(conference_records: [cr], next_page_token: nil))
    svc.stubs(:get_space).returns(OpenStruct.new(meeting_code: 'abc-defg-hjk', meeting_uri: 'https://meet.google.com/abc-defg-hjk'))
    svc.stubs(:list_conference_record_transcripts).returns(OpenStruct.new(transcripts: [transcript], next_page_token: nil))
    svc.stubs(:list_conference_record_transcript_entries).returns(OpenStruct.new(transcript_entries: [entry], next_page_token: nil))
    svc.stubs(:list_conference_record_participants).returns(OpenStruct.new(participants: participants, next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:meet_service).returns(svc)
    Stacks::Etl::Meet::CalendarEnricher.any_instance.stubs(:enrich).returns(title: 'Team Sync', attendees: [])
    svc
  end

  NOTES_MD = <<~MD
    # 📝 Notes

    ## Team Sync

    Invited [Alice](mailto:alice@x.co) [Bob](mailto:bob@x.co)

    ### Summary
    We aligned on the roadmap.
  MD

  test 'a conference record with a docsDestination yields a transcript + a gemini_notes record' do
    cr = OpenStruct.new(name: 'conferenceRecords/w1', start_time: '2026-01-01T09:00:00Z',
                        end_time: '2026-01-01T09:30:00Z', space: 'spaces/abc')
    transcript = OpenStruct.new(name: 'conferenceRecords/w1/transcripts/1',
                                docs_destination: OpenStruct.new(document: 'NOTES_DOC_1'))
    entry = OpenStruct.new(participant: 'p1', text: 'hello', start_time: '2026-01-01T09:01:00Z', end_time: '2026-01-01T09:01:05Z')
    participant = OpenStruct.new(name: 'p1', signedin_user: OpenStruct.new(display_name: 'Alice'))
    meet_svc_for(cr, transcript, entry, [participant])

    drive_svc = mock('drive')
    drive_svc.stubs(:export_file).with('NOTES_DOC_1', 'text/markdown').returns(NOTES_MD)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(drive_svc)

    yielded = []
    Stacks::Etl::Meet::MeetApiSource.new('hugh@sanctuary.computer').each_meeting { |n| yielded << n }

    assert_equal 2, yielded.size
    tx, notes = yielded
    assert_equal :meet, tx[:source]
    assert_equal 'conferenceRecords/w1', tx[:external_id]
    assert_equal :gemini_notes, notes[:source]
    assert_equal 'NOTES_DOC_1', notes[:external_id]
    assert_equal 'NOTES_DOC_1', notes[:transcript_doc_id]
    assert_equal ['alice@x.co', 'bob@x.co'], notes[:contacts].map { |c| c[:email] }
    joined = notes[:segments].map { |s| s[:text] }.join(' ')
    assert_includes joined, 'aligned on the roadmap'
    assert notes[:segments].all? { |s| s[:speaker_name].nil? }
  end

  test 'a docsDestination export failure skips notes but transcript is still yielded (best-effort)' do
    cr = OpenStruct.new(name: 'conferenceRecords/w2', start_time: '2026-01-01T09:00:00Z',
                        end_time: '2026-01-01T09:30:00Z', space: 'spaces/abc')
    transcript = OpenStruct.new(name: 'conferenceRecords/w2/transcripts/1',
                                docs_destination: OpenStruct.new(document: 'NOTES_DOC_FAIL'))
    entry = OpenStruct.new(participant: 'p1', text: 'hello', start_time: '2026-01-01T09:01:00Z', end_time: '2026-01-01T09:01:05Z')
    participant = OpenStruct.new(name: 'p1', signedin_user: OpenStruct.new(display_name: 'Alice'))
    meet_svc_for(cr, transcript, entry, [participant])

    drive_svc = mock('drive')
    drive_svc.stubs(:export_file).raises(StandardError, "no access")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(drive_svc)

    yielded = []
    assert_nothing_raised do
      Stacks::Etl::Meet::MeetApiSource.new('hugh@sanctuary.computer').each_meeting { |n| yielded << n }
    end
    assert_equal 1, yielded.size
    assert_equal :meet, yielded.first[:source], "transcript must still be yielded despite export failure"
  end

  test 'a deferred transcript (Drive doc already ingested) still yields the notes record' do
    # Drive backfill already created a Document keyed on the Drive doc id.
    Document.create!(source: :meet, external_id: 'NOTES_DOC_DEFERRED')
    cr = OpenStruct.new(name: 'conferenceRecords/w3', start_time: '2026-01-01T09:00:00Z',
                        end_time: '2026-01-01T09:30:00Z', space: 'spaces/abc')
    transcript = OpenStruct.new(name: 'conferenceRecords/w3/transcripts/1',
                                docs_destination: OpenStruct.new(document: 'NOTES_DOC_DEFERRED'))
    entry = OpenStruct.new(participant: 'p1', text: 'hello', start_time: '2026-01-01T09:01:00Z', end_time: '2026-01-01T09:01:05Z')
    participant = OpenStruct.new(name: 'p1', signedin_user: OpenStruct.new(display_name: 'Alice'))
    meet_svc_for(cr, transcript, entry, [participant])

    drive_svc = mock('drive')
    drive_svc.stubs(:export_file).with('NOTES_DOC_DEFERRED', 'text/markdown').returns(NOTES_MD)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(drive_svc)

    yielded = []
    Stacks::Etl::Meet::MeetApiSource.new('hugh@sanctuary.computer').each_meeting { |n| yielded << n }
    assert_equal 1, yielded.size
    assert_equal :gemini_notes, yielded.first[:source], "notes must still be yielded even when transcript is deferred"
    assert_equal 'NOTES_DOC_DEFERRED', yielded.first[:transcript_doc_id]
  end
```

- [ ] **Step 3: Run to verify new tests fail and existing pass**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/meet_api_source_test.rb`
Expected: existing tests PASS (with Auth.drive_service stubs added in Step 1); new tests FAIL — `MeetApiSource` doesn't include `NotesDoc`, doesn't have a drive service, and still uses `normalize` returning a single hash.

- [ ] **Step 4: Implement the refactor**

In `lib/stacks/etl/meet/meet_api_source.rb`, make these changes:

1. Add `include DriveDoc` and `include NotesDoc` at the class level (after the `require 'digest'` line):
```ruby
require 'digest'

module Stacks
  module Etl
    module Meet
      class MeetApiSource
        include DriveDoc
        include NotesDoc

        def initialize(admin_email, since: nil)
          @admin_email = admin_email
          @since = since.is_a?(String) ? Time.parse(since) : since
          @service = Auth.meet_service(sub: admin_email)
          @drive_service = Auth.drive_service(sub: admin_email)
          @enricher = CalendarEnricher.new(admin_email)
        end
```

2. Replace `each_meeting` to yield from `records_for(cr)`:
```ruby
        def each_meeting
          page = nil
          loop do
            opts = { page_token: page }
            opts[:filter] = "start_time >= \"#{@since.utc.iso8601}\"" if @since
            resp = @service.list_conference_records(**opts)
            Array(resp.conference_records).each do |cr|
              records_for(cr).each { |r| yield r }
            end
            page = resp.next_page_token
            break unless page
          end
        end
```

3. Rename `normalize` to `records_for` and make it return an array, then add `build_api_notes_record`:
```ruby
        private

        def records_for(cr)
          participants = fetch_participants(cr.name)
          segments, drive_doc_id = fetch_segments(cr.name, participants)
          # No transcript yet (still generating, or none): skip. The cursor LOOKBACK
          # re-checks recent meetings on later runs, so we pick it up once it's ready.
          return [] if segments.empty?

          text = segments.map { |s| s[:text] }.join("\n")
          code, uri = space_label(cr.space)
          enrichment = @enricher.enrich(started_at: cr.start_time, meeting_code: code, fallback_title: code || cr.space)
          title = enrichment[:title]
          contacts =
            if enrichment[:attendees].any?
              enrichment[:attendees].map { |a| { email: a[:email], name: a[:name], role: 'attendee' } }
            else
              participants.values.map { |p| { email: p[:email], name: p[:name], role: 'participant' } }
            end

          # If the Drive backfill already ingested this exact transcript, defer to it —
          # don't create a duplicate. Exclude THIS meeting's own row so a LOOKBACK re-scan
          # doesn't self-skip.
          deferred = drive_doc_id &&
                     Document.for_drive_doc(drive_doc_id).where.not(external_id: cr.name).exists?

          transcript = deferred ? nil : {
            external_id: cr.name,
            title: title,
            url: uri || (code ? "https://meet.google.com/#{code}" : nil),
            occurred_at: cr.start_time,
            content_hash: Digest::SHA256.hexdigest(text),
            participant_count: participants.size,
            contacts: contacts,
            segments: segments,
            raw_metadata: { 'conference_record' => cr.name, 'space' => cr.space, 'drive_doc_id' => drive_doc_id },
            build_source_record: ->(doc) { build_meeting(doc, cr, participants, segments, title, enrichment[:organizer_email]) }
          }

          notes = build_api_notes_record(cr, drive_doc_id, title, participants)
          [transcript, notes].compact
        end

        def build_api_notes_record(cr, drive_doc_id, title, participants)
          return nil unless drive_doc_id
          notes_export = @drive_service.export_file(drive_doc_id, "text/markdown")
          notes_md = split_transcript(notes_export).first
          emails = invited_emails_from(notes_export)
          occurred_at = coerce(cr.start_time)
          {
            source: :gemini_notes,
            external_id: drive_doc_id,
            title: title,
            url: "https://docs.google.com/document/d/#{drive_doc_id}",
            occurred_at: occurred_at,
            content_hash: Digest::SHA256.hexdigest(notes_md.to_s),
            contacts: emails.map { |e| { email: e, name: nil, role: "attendee" } },
            segments: notes_segments(notes_md, occurred_at: occurred_at),
            # transcript_doc_id = drive_doc_id: the notes doc IS the docsDestination doc,
            # so for_drive_doc(drive_doc_id) finds the transcript Document at ingest time
            # and Connector#exclusion_for inherits its privacy decision verbatim.
            transcript_doc_id: drive_doc_id,
            participant_count: participants.size, # fallback; connector prefers the join
            raw_metadata: { "gemini_notes_doc_id" => drive_doc_id, "transcript_doc_id" => drive_doc_id },
            build_source_record: ->(doc) {
              # Ingest-time join: transcript Document ingested just above us in this sweep.
              joined = Document.for_drive_doc(drive_doc_id).first&.source_record
              meeting = joined || Meeting.find_or_initialize_by(meet_conference_record_id: cr.name)
              meeting.update!(
                meet_source: joined ? meeting.meet_source : :meet_api,
                title: title,
                started_at: coerce(cr.start_time),
                gemini_notes_doc_id: drive_doc_id,
                raw_metadata: (meeting.raw_metadata || {}).merge("gemini_notes_document_id" => doc.id)
              )
              meeting
            }
          }
        rescue StandardError => e
          Rails.logger.warn("[meet_api] notes export skipped for #{drive_doc_id}: #{e.class}: #{e.message.to_s[0, 140]}")
          nil
        end
```

Keep `space_label`, `fetch_participants`, `fetch_segments`, and `build_meeting` unchanged.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/meet_api_source_test.rb`
Expected: PASS — all existing tests plus the three new notes tests.

(Typo in path above — use the correct path:)
Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/meet_api_source_test.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/stacks/etl/meet/meet_api_source.rb test/lib/stacks/etl/meet/meet_api_source_test.rb
git commit -m "MeetApiSource: emit gemini_notes record per docsDestination, best-effort (meeting-first API notes)"
```

---

### Task 5: Wire `parse_transcript:` through the connector, sweep, and rake

Thread `parse_transcript:` from the rake tasks through `sweep_all_users!` → `Connector` → `GeminiNotesSource`. The backfill sweep passes `true`; the daily notes sweep passes `false` (or omits, since `false` is the default).

**Files:**
- Modify: `lib/stacks/etl/meet/connector.rb`
- Modify: `lib/stacks/etl/meet.rb`
- Modify: `lib/tasks/etl.rake`
- Modify: `test/lib/stacks/etl/meet/sweep_test.rb`
- Modify: `test/lib/tasks/etl_rake_test.rb`

**Interfaces:**
- Consumes: `GeminiNotesSource.new(..., parse_transcript:)` from Task 2
- Produces: `Connector.new(admin_email:, mode:, parse_transcript: false)` (new kwarg); `sweep_all_users!(task_name:, mode:, since:, until_time: nil, parse_transcript: false)` (new kwarg)

- [ ] **Step 1: Update the rake tests**

In `test/lib/tasks/etl_rake_test.rb`, update the two sweep tests:

Replace the `backfill_meet_all` test:
```ruby
  test 'backfill_meet_all sweeps transcripts, then a gemini_notes sweep with parse_transcript: true' do
    seq = sequence('sweeps')
    Stacks::Etl::Meet.expects(:sweep_all_users!).with(has_entry(mode: :drive)).in_sequence(seq)
    Stacks::Etl::Meet.expects(:sweep_all_users!).with(has_entries(mode: :gemini_notes, until_time: nil, parse_transcript: true)).in_sequence(seq)
    Rake::Task['stacks:etl:backfill_meet_all'].reenable
    Rake::Task['stacks:etl:backfill_meet_all'].invoke('30')
  end
```

Replace the `sync_all` test:
```ruby
  test 'sync_all invokes sync_meet_all (api) before sync_gemini_notes_all (gemini_notes, parse_transcript: false)' do
    seq = sequence('sync_all_sweeps')
    Stacks::Etl::Meet.expects(:sweep_all_users!).with(has_entry(mode: :api)).in_sequence(seq)
    Stacks::Etl::Meet.expects(:sweep_all_users!).with(has_entries(mode: :gemini_notes, until_time: nil, parse_transcript: false)).in_sequence(seq)
    Rake::Task['stacks:etl:sync_meet_all'].reenable
    Rake::Task['stacks:etl:sync_gemini_notes_all'].reenable
    Rake::Task['stacks:etl:sync_all'].reenable
    Rake::Task['stacks:etl:sync_all'].invoke
  end
```

- [ ] **Step 2: Update the sweep test**

In `test/lib/stacks/etl/meet/sweep_test.rb`, the existing test calls `sweep_all_users!` without `parse_transcript:`. That still works (default is `false`). The connector stub uses `has_entry(admin_email: 'b@x.co')` which is a subset match and won't break when `parse_transcript: false` is added to the `Connector.new` call. No changes needed to sweep_test.rb.

However, confirm by running the test dry first (Step 4).

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/tasks/etl_rake_test.rb`
Expected: FAIL — `sweep_all_users!` doesn't yet accept `parse_transcript:`, and the rake tasks don't pass it.

- [ ] **Step 4: Add `parse_transcript:` to `Connector#initialize` and `source_object`**

In `lib/stacks/etl/meet/connector.rb`, update `initialize` and `source_object`:
```ruby
      class Connector < Stacks::Etl::Connector
        def initialize(admin_email:, mode: :api, since: nil, until_time: nil, parse_transcript: false)
          @admin_email = admin_email
          @mode = mode
          @since = since
          @until_time = until_time
          @parse_transcript = parse_transcript
        end

        def source = :meet

        def extract(since:)
          src = source_object(since || @since)
          Enumerator.new { |y| src.each_meeting { |n| y << n } }
        end

        def exclusion_for(normalized)
          if (tid = normalized[:transcript_doc_id])
            tdoc = Document.for_drive_doc(tid).first
            return [tdoc.excluded.to_sym, tdoc.excluded_reason.to_sym] if tdoc
          end
          count = normalized[:participant_count] || normalized[:contacts].size
          Classifier.call(title: normalized[:title], participant_count: count)
        end

        private

        def source_object(since)
          case @mode
          when :drive        then DriveSource.new(@admin_email, since: since || 90.days.ago, until_time: @until_time)
          when :gemini_notes then GeminiNotesSource.new(@admin_email, since: since || 90.days.ago, until_time: @until_time, parse_transcript: @parse_transcript)
          else MeetApiSource.new(@admin_email, since: since)
          end
        end
      end
```

- [ ] **Step 5: Add `parse_transcript:` to `sweep_all_users!`**

In `lib/stacks/etl/meet.rb`, update `sweep_all_users!`:
```ruby
      def self.sweep_all_users!(task_name:, mode:, since:, until_time: nil, parse_transcript: false)
        system_task = SystemTask.create!(name: task_name)
        emails = Workspace.all_active_user_emails
        ok = 0
        failed = []

        emails.each do |email|
          Connector.new(admin_email: email, mode: mode, until_time: until_time, parse_transcript: parse_transcript).run(since: since, track: false)
          ok += 1
        rescue StandardError => e
          failed << "#{email}: #{e.class}: #{e.message.to_s[0, 140]}"
        end

        Rails.logger.info("[#{task_name}] #{ok}/#{emails.size} users ok, #{failed.size} failed")
        failed.first(25).each { |f| Rails.logger.warn("[#{task_name}] FAIL #{f}") }

        if ok.zero? && emails.any?
          system_task.mark_as_error(RuntimeError.new("#{task_name}: all #{emails.size} users failed; first: #{failed.first(3).join(' | ')}"))
        else
          system_task.mark_as_success
        end
        { ok: ok, failed: failed.size, total: emails.size }
      rescue StandardError => e
        system_task&.mark_as_error(e)
        raise
      end
```

- [ ] **Step 6: Update the rake tasks**

In `lib/tasks/etl.rake`, update `backfill_meet_all` and `sync_gemini_notes_all`:

In `backfill_meet_all`, change the gemini_notes sweep call:
```ruby
      Stacks::Etl::Meet.sweep_all_users!(
        task_name: 'stacks:etl:backfill_gemini_notes_all',
        mode: :gemini_notes,
        since: (args[:days] || 90).to_i.days.ago,
        until_time: nil,
        parse_transcript: true
      )
```

In `sync_gemini_notes_all`, add `parse_transcript: false` explicitly:
```ruby
    task :sync_gemini_notes_all, [:days] => :environment do |_t, args|
      Stacks::Etl::Meet.sweep_all_users!(
        task_name: 'stacks:etl:sync_gemini_notes_all',
        mode: :gemini_notes,
        since: (args[:days] || 10).to_i.days.ago,
        until_time: nil,
        parse_transcript: false
      )
    end
```

- [ ] **Step 7: Run all affected tests to verify they pass**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/tasks/etl_rake_test.rb test/lib/stacks/etl/meet/sweep_test.rb test/lib/stacks/etl/meet/connector_test.rb`
Expected: PASS — rake tests assert `parse_transcript: true/false`; sweep tests still pass (subset match); connector tests pass (new kwarg defaults to false).

- [ ] **Step 8: Commit**

```bash
git add lib/stacks/etl/meet/connector.rb lib/stacks/etl/meet.rb lib/tasks/etl.rake \
        test/lib/tasks/etl_rake_test.rb
git commit -m "Wire parse_transcript: through Connector / sweep_all_users! / rake (backfill=true, daily=false)"
```

---

### Task 6: End-to-end connector test for the API notes path

Prove through a full ingest run that a mocked conference record with a `docsDestination` produces a chunked `source: meet` transcript + a `source: gemini_notes` notes doc on ONE Meeting, and that a 1:1 (≤2 participants) walls both. This is a verification test — no new production code.

**Files:**
- Modify: `test/lib/stacks/etl/meet/connector_test.rb`

**Interfaces:**
- Consumes: all of Tasks 1–5; `Connector.new(admin_email:, mode: :api).run(track: false)`
- Produces: DB assertions — two Documents on one Meeting, exclusion inherited, chunks present/absent

- [ ] **Step 1: Write the end-to-end test**

Add to `test/lib/stacks/etl/meet/connector_test.rb`:
```ruby
  test "API path: conference record with docsDestination ingests transcript + notes on one Meeting; 1:1 walled" do
    skip_without_pgvector

    # Two conference records: one group meeting, one 1:1.
    cr_group = OpenStruct.new(name: 'conferenceRecords/g1', start_time: '2026-01-01T09:00:00Z',
                               end_time: '2026-01-01T09:30:00Z', space: 'spaces/g1')
    cr_11    = OpenStruct.new(name: 'conferenceRecords/oo1', start_time: '2026-01-01T10:00:00Z',
                               end_time: '2026-01-01T10:30:00Z', space: 'spaces/oo1')

    tx_group = OpenStruct.new(name: 'conferenceRecords/g1/transcripts/1',
                               docs_destination: OpenStruct.new(document: 'NOTES_DOC_G1'))
    tx_11    = OpenStruct.new(name: 'conferenceRecords/oo1/transcripts/1',
                               docs_destination: OpenStruct.new(document: 'NOTES_DOC_OO1'))

    entry_g  = OpenStruct.new(participant: 'p1', text: 'roadmap decision', start_time: '2026-01-01T09:01:00Z', end_time: '2026-01-01T09:01:05Z')
    entry_oo = OpenStruct.new(participant: 'p1', text: 'sensitive', start_time: '2026-01-01T10:01:00Z', end_time: '2026-01-01T10:01:05Z')

    # 3 participants in the group meeting; 2 in the 1:1.
    parts_g  = [%w[p1 Alice], %w[p2 Bob], %w[p3 Carol]].map { |n, d| OpenStruct.new(name: n, signedin_user: OpenStruct.new(display_name: d)) }
    parts_oo = [%w[p1 Drew], %w[p2 Hugh]].map { |n, d| OpenStruct.new(name: n, signedin_user: OpenStruct.new(display_name: d)) }

    meet_svc = mock('meet')
    meet_svc.stubs(:list_conference_records).returns(
      OpenStruct.new(conference_records: [cr_group, cr_11], next_page_token: nil)
    )
    meet_svc.stubs(:get_space).returns(OpenStruct.new(meeting_code: 'abc', meeting_uri: 'https://meet.google.com/abc'))
    meet_svc.stubs(:list_conference_record_transcripts).with('conferenceRecords/g1', page_token: nil)
            .returns(OpenStruct.new(transcripts: [tx_group], next_page_token: nil))
    meet_svc.stubs(:list_conference_record_transcripts).with('conferenceRecords/oo1', page_token: nil)
            .returns(OpenStruct.new(transcripts: [tx_11], next_page_token: nil))
    meet_svc.stubs(:list_conference_record_transcript_entries)
            .with('conferenceRecords/g1/transcripts/1', page_size: 100, page_token: nil)
            .returns(OpenStruct.new(transcript_entries: [entry_g], next_page_token: nil))
    meet_svc.stubs(:list_conference_record_transcript_entries)
            .with('conferenceRecords/oo1/transcripts/1', page_size: 100, page_token: nil)
            .returns(OpenStruct.new(transcript_entries: [entry_oo], next_page_token: nil))
    meet_svc.stubs(:list_conference_record_participants).with('conferenceRecords/g1', page_token: nil)
            .returns(OpenStruct.new(participants: parts_g, next_page_token: nil))
    meet_svc.stubs(:list_conference_record_participants).with('conferenceRecords/oo1', page_token: nil)
            .returns(OpenStruct.new(participants: parts_oo, next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:meet_service).returns(meet_svc)
    Stacks::Etl::Meet::CalendarEnricher.any_instance.stubs(:enrich).returns(title: 'Team Sync', attendees: [])

    notes_group_md = "# 📝 Notes\n\n## Team Sync\n\nInvited [A](mailto:alice@x.co) [B](mailto:bob@x.co) [C](mailto:carol@x.co)\n\n### Summary\nRoadmap aligned.\n"
    notes_11_md    = "# 📝 Notes\n\n## Drew & Hugh\n\nInvited [D](mailto:drew@x.co) [H](mailto:hugh@x.co)\n\n### Summary\nSensitive 1:1 content.\n"

    drive_svc = mock('drive')
    drive_svc.stubs(:export_file).with('NOTES_DOC_G1', 'text/markdown').returns(notes_group_md)
    drive_svc.stubs(:export_file).with('NOTES_DOC_OO1', 'text/markdown').returns(notes_11_md)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(drive_svc)

    Stacks::Etl::Meet::Connector.new(admin_email: 'hugh@sanctuary.computer', mode: :api).run(track: false)

    # Group meeting — both documents eligible and chunked.
    tx_g = Document.find_by!(source: :meet, external_id: 'conferenceRecords/g1')
    nt_g = Document.find_by!(source: :gemini_notes, external_id: 'NOTES_DOC_G1')
    assert tx_g.not_excluded?, "group transcript must be eligible"
    assert nt_g.not_excluded?, "group notes must inherit eligibility"
    assert tx_g.chunks.any?, "transcript must be chunked"
    assert nt_g.chunks.any?, "notes must be chunked"
    assert_equal tx_g.source_record_id, nt_g.source_record_id, "transcript and notes must share one Meeting"
    assert_equal 'NOTES_DOC_G1', nt_g.raw_metadata['gemini_notes_doc_id']

    # 1:1 meeting — both documents walled (0 chunks).
    tx_oo = Document.find_by!(source: :meet, external_id: 'conferenceRecords/oo1')
    nt_oo = Document.find_by!(source: :gemini_notes, external_id: 'NOTES_DOC_OO1')
    assert tx_oo.auto_excluded?, "1:1 transcript must be auto-excluded by participant count"
    assert tx_oo.reason_one_on_one?
    assert nt_oo.auto_excluded?, "notes must inherit the 1:1 exclusion"
    assert_equal 0, tx_oo.chunks.count
    assert_equal 0, nt_oo.chunks.count
  end
```

- [ ] **Step 2: Run the e2e test**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && bin/rails test test/lib/stacks/etl/meet/connector_test.rb -n /API path/`
Expected: PASS (locally pgvector available; CI skips via `skip_without_pgvector`). If it fails, diagnose the root cause — the production code was implemented in Tasks 1–5, so failures indicate a bug there. Fix the bug, do NOT alter the test to hide it.

- [ ] **Step 3: Run the full ETL + rake suite**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && bin/rails test test/lib/stacks/etl test/lib/tasks/etl_rake_test.rb`
Then CI-mirror (no pgvector):
`cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl test/lib/tasks/etl_rake_test.rb`
Expected: both green (embedding-touching tests skip under DISABLE_PGVECTOR).

- [ ] **Step 4: Commit**

```bash
git add test/lib/stacks/etl/meet/connector_test.rb
git commit -m "E2E: API path yields transcript + notes on one Meeting; 1:1 walled by participant count"
```

---

## Self-Review

**Spec coverage:**
- `NotesDoc` module with `split_transcript`, `invited_emails_from`, `notes_segments` → Task 1 ✓
- `GeminiNotesSource` `parse_transcript:` flag, daily notes-only skip, backfill combined behavior → Task 2 ✓
- Canary: substantial 0-speaker transcript section logs error; empty section does not → Task 3 ✓
- `MeetApiSource` Drive service, `include NotesDoc`, `records_for` returns array, `build_api_notes_record` best-effort → Task 4 ✓
- `Connector` + `sweep_all_users!` + rake wiring; `backfill_meet_all` passes `true`, `sync_gemini_notes_all` passes `false` → Task 5 ✓
- E2E: API path yields transcript + notes on one Meeting; 1:1 walled; deferred transcript → notes only → Tasks 4 + 6 ✓
- Privacy wall: transcript classified by real participants; notes inherit via `for_drive_doc(transcript_doc_id)` → connector `exclusion_for` (existing, unchanged) + `transcript_doc_id: drive_doc_id` in notes records → Tasks 4, 6 ✓
- Best-effort: export failure → transcript only, no crash → Task 4 `rescue StandardError` in `build_api_notes_record` ✓
- `parse_transcript` deferred transcript emits notes → Task 4 `deferred` check + `[nil, notes].compact` ✓

**Placeholder scan:** No TBD/TODO. Every step shows complete Ruby. Commands are exact with expected output.

**Type consistency:**
- `notes_segments(markdown, occurred_at:)` defined in `NotesDoc` (Task 1), called in `GeminiNotesSource#note_record` and `MeetApiSource#build_api_notes_record` (Tasks 1, 4). ✓
- `split_transcript(text) -> [notes_md, transcript_md]` in `NotesDoc` (Task 1), called in `GeminiNotesSource#records_for`, `MeetApiSource#build_api_notes_record` (Tasks 2, 4). ✓
- `invited_emails_from(text) -> Array<String>` in `NotesDoc` (Task 1), called in both sources. ✓
- `parse_transcript: false` kwarg: `GeminiNotesSource#initialize` (Task 2) → `Connector#source_object` (Task 5) → `sweep_all_users!` (Task 5) → rake (Task 5). All four sites use `parse_transcript:` consistently. ✓
- `transcript_doc_id: drive_doc_id` in notes hash from `MeetApiSource` (Task 4); consumed by `Connector#exclusion_for` (existing `normalized[:transcript_doc_id]`) and `build_source_record` lambda (Task 4). ✓
- `Document.for_drive_doc(drive_doc_id)` scope (existing, unmodified) used in daily-mode skip (Task 2), deferred check in `MeetApiSource#records_for` (Task 4), and `build_source_record` lambda (Task 4). ✓
- `records_for(cr) -> Array` in `MeetApiSource` (Task 4); `records_for(file) -> Array` in `GeminiNotesSource` (existing, unchanged interface). Both return `Array` iterated in `each_meeting`. ✓
