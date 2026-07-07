# Meet Combined Notes+Transcript Format — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ingest Google Meet's newer combined "Notes by Gemini" doc (transcript embedded as a tab) as a proper `source: meet` transcript classified by real speakers, plus a `source: gemini_notes` notes doc that inherits it — instead of one mis-tagged notes doc classified on invited count.

**Architecture:** `GeminiNotesSource` detects the combined format (the `[Transcript]` link points to the doc's own id), splits the markdown at the transcript heading, and yields TWO normalized records from the one file (transcript first, then notes). The transcript is keyed/deduped exactly like a `DriveSource` transcript; the notes join to it via the existing `for_drive_doc(file.id)` path. To make that same-sweep join resolve correctly, notes→transcript inheritance and meeting-linking move to **ingest time** (lazy). The transcript speaker parser is extracted into a shared module.

**Tech Stack:** Ruby 3.1 / Rails 6.1, Minitest + mocha (no WebMock), PostgreSQL + pgvector (`neighbor`), local ONNX embeddings.

## Global Constraints

- Transcripts stay load-bearing: `MeetApiSource` and old-format `DriveSource` behavior UNCHANGED except a pure parser move (Task 1).
- Privacy wall: excluded meetings are never chunked/embedded/returned. The split transcript is classified by ACTUAL distinct speakers (never invited count); the notes inherit its `excluded`/`excluded_reason` verbatim.
- Progressive enhancement: combined-format handling is additive; nothing depends on it.
- Combined detection signal: `transcript_doc_id_from(markdown) == file.id` (self-referencing link).
- Split point: the first markdown heading (`#`/`##`) whose text contains "Transcript" (tolerant of the `📖` emoji). If absent → notes-only.
- Empty transcript (0 speaker segments) → notes-only, no `meet` Document.
- Reverse-dedup: the split transcript defers to an existing transcript Document via `Document.for_drive_doc(file.id).where.not(external_id: file.id).exists?` (API/Drive already ingested it); the notes then inherit from that existing Document.
- Notes doc keeps `source: gemini_notes`, `external_id: file.id`; transcript doc is `source: meet`, `external_id: file.id` (distinct rows, same Meeting).
- CI uses in-dyno Postgres with NO pgvector: any test that ingests/embeds must call `skip_without_pgvector`. `schema.rb` hand-manages pgvector omissions (do not touch).
- Contact source tag stays `etl:meet`.

---

### Task 1: Extract the shared transcript speaker parser

**Files:**
- Create: `lib/stacks/etl/meet/transcript_segments.rb`
- Modify: `lib/stacks/etl/meet/drive_source.rb` (remove the moved constants/methods, `include TranscriptSegments`)
- Test: `test/lib/stacks/etl/meet/transcript_segments_test.rb` (new); existing `test/lib/stacks/etl/meet/drive_source_test.rb` must still pass unchanged.

**Interfaces:**
- Produces: module `Stacks::Etl::Meet::TranscriptSegments` with instance methods `parse_segments(text) -> Array<{speaker_name:, speaker_email:, text:, started_at:, ended_at:}>` (started_at/ended_at nil; caller stamps started_at) and `distinct_speaker_count(segments) -> Integer`, plus constants `NAME_HEAD`, `NAME_TAIL`, `ANON_LABEL`, `SPEAKER_LINE`.

- [ ] **Step 1: Write the failing test**

Create `test/lib/stacks/etl/meet/transcript_segments_test.rb`:
```ruby
require "test_helper"

class Stacks::Etl::Meet::TranscriptSegmentsTest < ActiveSupport::TestCase
  # A tiny host so we can call the module's instance methods.
  class Host
    include Stacks::Etl::Meet::TranscriptSegments
  end
  def parser = Host.new

  test "parses Name: text speaker lines, ignoring non-speaker lines" do
    segs = parser.parse_segments("Drew Smith: we should ship\nhttps://x was shared\n10:30 break\nHugh: agreed")
    assert_equal ["Drew Smith", "Hugh"], segs.map { |s| s[:speaker_name] }
    assert_equal "we should ship", segs.first[:text]
  end

  test "a mid-sentence colon does not spawn a phantom speaker (1:1 count honesty)" do
    segs = parser.parse_segments("Alice: I think the answer is: yes\nBob: agreed")
    assert_equal ["Alice", "Bob"], segs.map { |s| s[:speaker_name] }
  end

  test "recognizes Meet anonymous 'Speaker N' labels" do
    segs = parser.parse_segments("Speaker 1: hello\nSpeaker 2: hi\nAlice: welcome")
    assert_equal ["Speaker 1", "Speaker 2", "Alice"], segs.map { |s| s[:speaker_name] }
  end

  test "distinct_speaker_count counts unique speakers" do
    segs = parser.parse_segments("Alice: hi\nBob: yo\nAlice: bye")
    assert_equal 2, parser.distinct_speaker_count(segs)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/transcript_segments_test.rb`
Expected: FAIL — `uninitialized constant Stacks::Etl::Meet::TranscriptSegments`.

- [ ] **Step 3: Create the module (verbatim move from DriveSource)**

Create `lib/stacks/etl/meet/transcript_segments.rb`:
```ruby
module Stacks
  module Etl
    module Meet
      # Speaker-line parsing for Google Meet transcripts, shared by DriveSource (standalone
      # "- Transcript" docs) and GeminiNotesSource (transcript embedded in a combined
      # "Notes by Gemini" doc). Moved verbatim from DriveSource — behavior unchanged.
      module TranscriptSegments
        # A speaker line is "Name: <text>". The FIRST token (NAME_HEAD) must start with an
        # uppercase letter (\p{Lu}) or a caseless-script letter (\p{Lo}, e.g. CJK) — that
        # rejects timestamps ("10:30 …"), spoken sentences ("i think the answer is: yes") AND
        # a leading parenthetical ("(Recording note): …"). Trailing tokens (NAME_TAIL) may add
        # more letter-words or a "(Guest)" parenthetical, but NOT bare numbers, so body lines
        # like "Action 1:" / "Phase 2:" don't parse as speakers (a phantom speaker would
        # inflate the distinct-speaker 1:1 count and leak a private 1:1). Meet's anonymous
        # labels are matched explicitly as "Speaker N" etc.
        NAME_HEAD = /[\p{Lu}\p{Lo}][\p{L}.'’-]*/
        NAME_TAIL = /(?:[\p{Lu}\p{Lo}][\p{L}.'’-]*|\([^)]*\))/
        ANON_LABEL = /(?:Speaker|Guest|Participant) \d{1,4}/
        SPEAKER_LINE = /\A\s*(#{ANON_LABEL}|#{NAME_HEAD}(?:[ ,&]+#{NAME_TAIL}){0,6}):\s+(\S.*)\z/

        def parse_segments(text)
          text.to_s.each_line.filter_map do |raw|
            if (m = raw.chomp.match(SPEAKER_LINE))
              { speaker_name: m[1].strip, speaker_email: nil, text: m[2].strip, started_at: nil, ended_at: nil }
            end
            # Lines without a name-shaped "Name:" prefix — system/footer notes like
            # "Recording stopped" or "X left the call" — are dropped rather than misattributed.
          end
        end

        # Distinct speakers heard — the actual-attendance head-count for the 1:1 privacy
        # classifier. parse_segments never yields a nil speaker_name.
        def distinct_speaker_count(segments)
          segments.map { |s| s[:speaker_name] }.uniq.size
        end
      end
    end
  end
end
```

- [ ] **Step 4: Update DriveSource to include the module and drop the moved code**

In `lib/stacks/etl/meet/drive_source.rb`:
1. Add `include TranscriptSegments` right after `include DriveDoc` (line 7).
2. DELETE the now-duplicated constants and methods: `NAME_HEAD`, `NAME_TAIL`, `ANON_LABEL`, `SPEAKER_LINE` (the four constant lines), `def parse_segments ... end`, and `def distinct_speaker_count ... end`. Leave everything else (QUERY, initialize, each_meeting, normalize, build_meeting, the comments) untouched.

Result: `class DriveSource` starts:
```ruby
      class DriveSource
        include DriveDoc
        include TranscriptSegments

        QUERY = "mimeType='application/vnd.google-apps.document' and name contains 'Transcript'".freeze
```
and no longer defines `parse_segments`, `distinct_speaker_count`, or the four constants.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/transcript_segments_test.rb test/lib/stacks/etl/meet/drive_source_test.rb`
Expected: PASS — the new module tests pass AND every existing DriveSource speaker/parse test passes unchanged (the move is behavior-preserving).

- [ ] **Step 6: Commit**

```bash
git add lib/stacks/etl/meet/transcript_segments.rb lib/stacks/etl/meet/drive_source.rb test/lib/stacks/etl/meet/transcript_segments_test.rb
git commit -m "Extract shared TranscriptSegments speaker parser from DriveSource"
```

---

### Task 2: Resolve notes→transcript inheritance & meeting-link at ingest time (lazy)

**Why:** For a combined file, the transcript and notes records are produced together but ingested one after another. If the notes eager-resolve their transcript at build time (as today), they won't see the just-created transcript. Moving resolution to ingest time fixes this and is behavior-preserving for the existing case (a prior-sweep transcript exists at both times).

**Files:**
- Modify: `lib/stacks/etl/meet/connector.rb` (`exclusion_for`)
- Modify: `lib/stacks/etl/meet/gemini_notes_source.rb` (`normalize` drops the eager join; `build_meeting` resolves the meeting lazily)
- Test: `test/lib/stacks/etl/meet/gemini_notes_source_test.rb` (update assertions), `test/lib/stacks/etl/meet/connector_test.rb`

**Interfaces:**
- Consumes: `Document.for_drive_doc(id)` (returns `meet`-scoped Documents matching `external_id` OR `raw_metadata->>'drive_doc_id'`).
- Produces: a `gemini_notes` normalized hash now carries `transcript_doc_id:` (the parsed id or nil) and always `participant_count:` (invited count, the standalone fallback). It NO LONGER carries `inherit_exclusion`. `Meet::Connector#exclusion_for` resolves the transcript at ingest and inherits when found.

- [ ] **Step 1: Update the source tests to the new contract**

In `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`, the source no longer computes `inherit_exclusion`; it emits `transcript_doc_id` + `participant_count`, and inheritance is asserted through the connector (Task 5 covers the wall). Update the two join tests:

Replace the assertion block in `test "joins a notes doc to the existing transcript's meeting and inherits its exclusion"` — change:
```ruby
    assert_equal [:auto_excluded, :one_on_one], n[:inherit_exclusion]
```
to:
```ruby
    assert_equal "TRANSCRIPT_ID_123", n[:transcript_doc_id]   # inheritance resolved at ingest via for_drive_doc
```
Keep the rest of that test (the `build_source_record.call(doc)` → same meeting assertion) as-is.

In `test "joining an ELIGIBLE transcript inherits not_excluded verbatim (notes stay searchable)"`, replace:
```ruby
    assert_equal [:not_excluded, :none], n[:inherit_exclusion]
    assert_nil n[:participant_count]
```
with:
```ruby
    assert_equal "TRANSCRIPT_ID_123", n[:transcript_doc_id]
```

In `test "joins to API-ingested transcript keyed by conference-record id (regression: for_drive_doc vs find_by)"`, replace:
```ruby
    assert_equal [:auto_excluded, :one_on_one], n[:inherit_exclusion],
                 "Expected exclusion to be inherited from API-ingested transcript; standalone path would incorrectly allow this meeting"
    assert_nil n[:participant_count], "Expected nil participant_count (took join path, not standalone)"
```
with:
```ruby
    assert_equal "REAL_TRANSCRIPT_DRIVE_ID", n[:transcript_doc_id],
                 "Notes carry the parsed transcript id; the connector inherits from the API-ingested transcript at ingest"
```

In `test "a notes doc with no known transcript is standalone with its own classification"`, replace:
```ruby
    assert_nil n[:inherit_exclusion]
    assert_equal 3, n[:participant_count]
```
with:
```ruby
    assert_nil n[:transcript_doc_id]
    assert_equal 3, n[:participant_count]  # invited count -> classifier sees a group
```

In `test "exports the notes doc as text/markdown so hyperlinks (mailto + transcript) survive"`, replace:
```ruby
    assert_equal [:not_excluded, :none], n[:inherit_exclusion]
```
with:
```ruby
    assert_equal "TRANSCRIPT_ID_123", n[:transcript_doc_id]
```

- [ ] **Step 2: Add the connector inheritance test**

In `test/lib/stacks/etl/meet/connector_test.rb`, add a focused unit test of `exclusion_for` (no DB embeddings needed, so NO skip guard):
```ruby
  test "exclusion_for inherits a joined transcript's decision at ingest, else classifies on count" do
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/inh")
    Document.create!(source: :meet, external_id: "TX1", source_record: m,
                     excluded: :auto_excluded, excluded_reason: :one_on_one)
    conn = Stacks::Etl::Meet::Connector.new(admin_email: "a@x.co", mode: :gemini_notes)

    # joined: resolves TX1 via for_drive_doc and inherits verbatim
    joined = conn.exclusion_for(transcript_doc_id: "TX1", title: "Anything", participant_count: 9, contacts: [])
    assert_equal [:auto_excluded, :one_on_one], joined

    # standalone: no resolvable transcript -> classify on the count
    standalone = conn.exclusion_for(transcript_doc_id: "NOPE", title: "Team Weekly", participant_count: 5, contacts: [])
    assert_equal [:not_excluded, :none], standalone
  end
```

- [ ] **Step 3: Run to verify failure**

Run (connector_test's `setup` calls `skip_without_pgvector`, so run it WITHOUT the DISABLE flag — locally pgvector is available; the non-DB source test can use the flag):
```
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && \
  DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb && \
  bin/rails test test/lib/stacks/etl/meet/connector_test.rb -n /exclusion_for inherits/
```
Expected: FAIL — source still returns `inherit_exclusion`; `exclusion_for` doesn't yet resolve `transcript_doc_id`.

- [ ] **Step 4: Move resolution to ingest time**

In `lib/stacks/etl/meet/connector.rb`, replace `exclusion_for` with:
```ruby
        def exclusion_for(normalized)
          # Resolve a notes doc's transcript at INGEST time (not in the source): the transcript
          # Document is guaranteed present by now — whether ingested in an earlier sweep, or as
          # the transcript half of the SAME combined "Notes by Gemini" file yielded just before
          # this notes record. Inherit its decision verbatim (identical privacy wall).
          if (tid = normalized[:transcript_doc_id])
            tdoc = Document.for_drive_doc(tid).first
            return [tdoc.excluded.to_sym, tdoc.excluded_reason.to_sym] if tdoc
          end
          # 1:1 PRIVACY POLICY (deliberate — do NOT max() with the contacts/Calendar count): the
          # head-count must reflect who was ACTUALLY in the meeting, never who was invited.
          # Invite counts over-count (a no-show on a 1:1 makes it look like a group and the
          # private transcript leaks). Use the actual-attendance signal each source provides —
          # Meet participants (API) or distinct speakers (Drive/combined) — in participant_count,
          # even when 0 ("couldn't confirm a group" -> conservatively excluded). Only when that
          # signal is wholly ABSENT (nil) fall back to the contact count.
          count = normalized[:participant_count] || normalized[:contacts].size
          Classifier.call(title: normalized[:title], participant_count: count)
        end
```

In `lib/stacks/etl/meet/gemini_notes_source.rb`, change `normalize` so it (a) stops eager-joining, (b) always sets `transcript_doc_id` + `participant_count`, and (c) passes `transcript_id` to `build_meeting` for lazy meeting resolution. Replace the body from the `# Join to the transcript's meeting` comment through the end of `normalize` with:
```ruby
          transcript_id = transcript_doc_id_from(text)
          emails = invited_emails_from(text)
          segments = body_segments(text, occurred_at: occurred_at)

          {
            source: :gemini_notes,
            external_id: file.id,
            title: title,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: occurred_at,
            content_hash: Digest::SHA256.hexdigest(text.to_s),
            contacts: emails.map { |e| { email: e, name: nil, role: "attendee" } },
            segments: segments,
            # transcript_doc_id drives BOTH inheritance (Connector#exclusion_for) and the
            # meeting-join (build_meeting), resolved at ingest via Document.for_drive_doc.
            transcript_doc_id: transcript_id,
            participant_count: emails.size, # standalone fallback when no transcript resolves
            raw_metadata: { "gemini_notes_doc_id" => file.id, "transcript_doc_id" => transcript_id },
            build_source_record: ->(doc) { build_meeting(doc, file, title, occurred_at, transcript_id) }
          }
```
(Delete the now-unused `emails` computed earlier in the method if it was moved; ensure `emails`/`segments`/`transcript_id` are computed once, as shown.)

Replace `build_meeting` with the lazy-meeting version:
```ruby
        def build_meeting(doc, file, title, occurred_at, transcript_id)
          # Resolve the joined meeting at INGEST time so a same-sweep combined transcript
          # (yielded just before us) is found. for_drive_doc matches DriveSource (external_id)
          # and MeetApiSource (raw_metadata.drive_doc_id) keying.
          joined = transcript_id && Document.for_drive_doc(transcript_id).first&.source_record
          meeting = joined || Meeting.find_or_initialize_by(gemini_notes_doc_id: file.id)
          meeting.update!(meet_source: (joined ? meeting.meet_source : :gemini_notes),
                          title: title, started_at: occurred_at,
                          gemini_notes_doc_id: file.id,
                          raw_metadata: (meeting.raw_metadata || {}).merge("gemini_notes_document_id" => doc.id))
          meeting
        end
```

- [ ] **Step 5: Run to verify pass**

Run:
```
cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && \
  DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb && \
  bin/rails test test/lib/stacks/etl/meet/connector_test.rb
```
Expected: PASS (the source tests on the CI-mirror flag; the full connector_test with pgvector available locally).

- [ ] **Step 6: Commit**

```bash
git add lib/stacks/etl/meet/connector.rb lib/stacks/etl/meet/gemini_notes_source.rb test/lib/stacks/etl/meet/gemini_notes_source_test.rb test/lib/stacks/etl/meet/connector_test.rb
git commit -m "Resolve notes->transcript inheritance + meeting-join at ingest (enables same-sweep combined join)"
```

---

### Task 3: Detect the combined format and split its markdown

**Files:**
- Modify: `lib/stacks/etl/meet/gemini_notes_source.rb` (add `combined_format?`, `split_transcript`)
- Test: `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`

**Interfaces:**
- Produces (private): `combined_format?(text, file_id) -> Boolean` (true when the parsed transcript id equals the file's own id); `split_transcript(text) -> [notes_md, transcript_md]` where `transcript_md` is `""` when no transcript heading is present.

- [ ] **Step 1: Write the failing test**

Add to `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`:
```ruby
  COMBINED = <<~TXT
    # **📝 Notes**

    ## **Business Meeting**

    Invited [Alice](mailto:alice@x.co) [Bob](mailto:bob@x.co) [Carol](mailto:carol@x.co)

    Meeting records [Transcript](https://docs.google.com/document/d/SELF_ID/edit?usp=drive_web&tab=t.wqjj)

    ### Summary
    We planned the sprint.

    # **📖 Transcript**

    ## **Business Meeting \\- Transcript**

    Alice: kicking off the sprint
    Bob: sounds good to me
    Carol: agreed
  TXT

  test "detects the combined format when the transcript link points to the doc's own id" do
    assert src.send(:combined_format?, COMBINED, "SELF_ID")
    refute src.send(:combined_format?, COMBINED, "OTHER_ID")  # external transcript -> old format
    refute src.send(:combined_format?, "no transcript link here", "SELF_ID")
  end

  test "splits combined markdown into notes-body and transcript at the transcript heading" do
    notes_md, transcript_md = src.send(:split_transcript, COMBINED)
    assert_includes notes_md, "We planned the sprint"
    refute_includes notes_md, "kicking off the sprint"      # transcript dialogue not in notes
    assert_includes transcript_md, "Alice: kicking off the sprint"
    assert_includes transcript_md, "Carol: agreed"
  end

  test "split returns empty transcript when there is no transcript heading" do
    notes_md, transcript_md = src.send(:split_transcript, "# Notes\n\n### Summary\nJust notes.")
    assert_includes notes_md, "Just notes."
    assert_equal "", transcript_md
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb -n /combined|splits|split returns/`
Expected: FAIL — `combined_format?` / `split_transcript` undefined.

- [ ] **Step 3: Implement detection + split**

In `lib/stacks/etl/meet/gemini_notes_source.rb`, add these private methods (near `transcript_doc_id_from`). Also add `include TranscriptSegments` after `include DriveDoc` (line 6) — used in Task 4.
```ruby
        # The transcript is EMBEDDED in this notes doc (newer Meet format) when its
        # "Meeting records [Transcript](…/document/d/<id>)" link points to the doc's OWN id.
        def combined_format?(text, file_id)
          transcript_doc_id_from(text) == file_id
        end

        # First markdown heading whose text contains "Transcript" — tolerant of the 📖 emoji so
        # a future Google change doesn't break it. The inline "Meeting records [Transcript](…)"
        # link is NOT a heading and is not matched.
        TRANSCRIPT_HEADING = /^\#{1,2}\s+.*Transcript.*$/i

        # Split a combined doc into [notes_body_markdown, transcript_markdown]. Everything from
        # the transcript heading onward is the transcript; everything before is the notes body.
        # Returns transcript_md = "" when no transcript heading is present (caller falls back to
        # notes-only).
        def split_transcript(text)
          s = text.to_s
          if (m = s.match(TRANSCRIPT_HEADING))
            [s[0...m.begin(0)], s[m.begin(0)..]]
          else
            [s, ""]
          end
        end
```

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb`
Expected: PASS (all, including the Task 2 ones).

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/meet/gemini_notes_source.rb test/lib/stacks/etl/meet/gemini_notes_source_test.rb
git commit -m "GeminiNotesSource: detect combined Notes+Transcript format and split markdown"
```

---

### Task 4: Yield two records (transcript + notes) from a combined file

**Files:**
- Modify: `lib/stacks/etl/meet/gemini_notes_source.rb` (`each_meeting`, add `records_for`, `transcript_record`)
- Test: `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`

**Interfaces:**
- Consumes: `combined_format?`, `split_transcript` (Task 3); `parse_segments`, `distinct_speaker_count` (Task 1); the notes hash from `normalize` (Task 2).
- Produces: `each_meeting` yields one hash for a plain/old-format notes doc, and TWO hashes for a combined doc with a real transcript — transcript first (`source: :meet`), then notes (`source: :gemini_notes`). Reverse-dedup omits the transcript record when an existing transcript Document already covers `file.id`.

- [ ] **Step 1: Write the failing test**

Add to `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`:
```ruby
  def combined_file = OpenStruct.new(id: "SELF_ID", name: "Business Meeting - 2026/06/30 15:00 EDT - Notes by Gemini",
                                     created_time: "2026-06-30T15:00:00Z")

  def stub_drive_returning(text, file: combined_file)
    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns(text)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)
    svc
  end

  test "a combined doc yields a meet transcript record then a gemini_notes record, both for the same file" do
    stub_drive_returning(COMBINED)
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |r| out << r }

    assert_equal [:meet, :gemini_notes], out.map { |r| r[:source] }
    tx, notes = out
    assert_equal "SELF_ID", tx[:external_id]
    assert_equal ["Alice", "Bob", "Carol"], tx[:segments].map { |s| s[:speaker_name] }
    assert_equal 3, tx[:participant_count]                 # actual speakers, not invited
    assert_equal "SELF_ID", tx[:raw_metadata]["drive_doc_id"]
    assert_equal "SELF_ID", notes[:transcript_doc_id]      # self-link -> inherits tx at ingest
    refute notes[:segments].any? { |s| s[:text].include?("kicking off the sprint") } # transcript not in notes
  end

  test "a combined doc whose transcript section has no speaker lines yields notes-only" do
    empty_tx = "# **📝 Notes**\n\n## **Quick Sync**\n\nInvited [A](mailto:a@x.co)\n\nMeeting records [Transcript](https://docs.google.com/document/d/SELF_ID/edit)\n\n### Summary\nShort.\n\n# **📖 Transcript**\n\n### Transcription ended after 00:01:30\n"
    stub_drive_returning(empty_tx)
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |r| out << r }
    assert_equal [:gemini_notes], out.map { |r| r[:source] }   # no meet transcript emitted
    assert_equal 1, out.first[:participant_count]              # standalone -> invited count
  end

  test "the split transcript defers to an already-ingested transcript Document (reverse dedup)" do
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/dup")
    Document.create!(source: :meet, external_id: "conferenceRecords/dup", source_record: m,
                     excluded: :not_excluded, excluded_reason: :none, raw_metadata: { "drive_doc_id" => "SELF_ID" })
    stub_drive_returning(COMBINED)
    out = []
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |r| out << r }
    assert_equal [:gemini_notes], out.map { |r| r[:source] } # transcript deferred; only notes yielded
    assert_equal "SELF_ID", out.first[:transcript_doc_id]     # notes still inherit from the API doc at ingest
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb -n /combined doc yields|notes-only|reverse dedup/`
Expected: FAIL — `each_meeting` yields one record; no transcript record.

- [ ] **Step 3: Implement the two-record yield**

In `lib/stacks/etl/meet/gemini_notes_source.rb`, change `each_meeting` to yield each record from `records_for`, and add `records_for` + `transcript_record`:
```ruby
        def each_meeting
          page = nil
          loop do
            q = "#{QUERY} and createdTime > '#{@since.utc.iso8601}'"
            q += " and createdTime < '#{@until_time.utc.iso8601}'" if @until_time
            resp = @service.list_files(q: q, fields: "nextPageToken, files(id,name,createdTime)", page_token: page)
            Array(resp.files).each { |f| records_for(f).each { |r| yield r } }
            page = resp.next_page_token
            break unless page
          end
        end
```
Add (private):
```ruby
        # A combined "Notes by Gemini" file yields TWO records (transcript first so the notes'
        # for_drive_doc(file.id) join resolves it at ingest); a plain/old-format notes doc yields
        # one. When combined, the notes body excludes the embedded transcript.
        def records_for(file)
          text = @service.export_file(file.id, "text/markdown")
          if combined_format?(text, file.id)
            notes_md, transcript_md = split_transcript(text)
            segments = parse_segments(transcript_md).each { |s| s[:started_at] = coerce(file.created_time) }
            if segments.any?
              tx = transcript_record(file, text, transcript_md, segments)
              # Reverse-dedup: if an API/Drive transcript Document already covers this file, don't
              # emit a duplicate transcript — the notes still inherit from it at ingest.
              [tx, note_record(file, notes_md, text)].compact
            else
              [note_record(file, notes_md, text)] # empty transcript -> notes-only
            end
          else
            [normalize(file, exported: text)] # old-format / notes-only
          end
        end

        # The embedded transcript as its own source:meet record, keyed/deduped exactly like a
        # DriveSource transcript (external_id + drive_doc_id = file.id; classified by real
        # speakers). Returns nil when an existing transcript Document already covers file.id.
        def transcript_record(file, full_text, transcript_md, segments)
          return nil if Document.for_drive_doc(file.id).where.not(external_id: file.id).exists?
          title = clean_title(file.name)
          occurred_at = coerce(file.created_time)
          emails = invited_emails_from(full_text)
          speaker_count = distinct_speaker_count(segments)
          {
            source: :meet,
            external_id: file.id,
            title: title,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: occurred_at,
            content_hash: Digest::SHA256.hexdigest(transcript_md.to_s),
            participant_count: speaker_count, # ACTUAL speakers drive the 1:1 head-count
            # Reuse the doc's Invited emails for attribution (no separate Calendar call needed);
            # attribution is separate from the speaker-based head-count above.
            contacts: emails.map { |e| { email: e, name: nil, role: "attendee" } },
            segments: segments,
            raw_metadata: { "drive_doc_id" => file.id, "combined_notes_doc_id" => file.id },
            build_source_record: ->(doc) { build_transcript_meeting(doc, file, title, occurred_at, speaker_count, segments) }
          }
        end

        # Meeting for the embedded transcript — keyed like DriveSource so notes join it.
        def build_transcript_meeting(doc, file, title, occurred_at, speaker_count, segments)
          meeting = Meeting.find_or_initialize_by(drive_transcript_doc_id: file.id)
          meeting.update!(meet_source: :drive, title: title, started_at: occurred_at,
                          participant_count: speaker_count,
                          raw_metadata: { "document_id" => doc.id })
          meeting.segments.destroy_all
          segments.each_with_index do |s, i|
            meeting.segments.create!(position: i, speaker_name: s[:speaker_name], text: s[:text], started_at: s[:started_at])
          end
          meeting
        end
```
Refactor `normalize` into a `note_record(file, notes_md, full_text)` that the combined path reuses for the notes half (notes body = `notes_md`; contacts/transcript_id from `full_text`), and have the non-combined path call `normalize(file, exported:)`:
```ruby
        # The gemini_notes (notes-body) record. `notes_md` is the notes portion only (for a
        # combined doc that's everything before the transcript heading; for a plain doc it's the
        # whole export). `full_text` is the full export, used for the invited emails and the
        # transcript link.
        def note_record(file, notes_md, full_text)
          title = clean_title(file.name)
          occurred_at = coerce(file.created_time)
          transcript_id = transcript_doc_id_from(full_text)
          emails = invited_emails_from(full_text)
          segments = body_segments(notes_md, occurred_at: occurred_at)
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

        # Old-format / notes-only: the notes body is the whole export.
        def normalize(file, exported: nil)
          text = exported || @service.export_file(file.id, "text/markdown")
          note_record(file, text, text)
        end
```
(Remove the old `normalize` body replaced above. Keep `transcript_doc_id_from`, `invited_emails_from`, `body_segments`, `build_meeting`, `combined_format?`, `split_transcript`.)

- [ ] **Step 4: Run to verify pass**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb`
Expected: PASS (all — combined, notes-only, reverse-dedup, and the Task 2/3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/meet/gemini_notes_source.rb test/lib/stacks/etl/meet/gemini_notes_source_test.rb
git commit -m "GeminiNotesSource: yield split transcript + notes records from a combined doc"
```

---

### Task 5: End-to-end connector ingest of a combined doc

**Files:**
- Test: `test/lib/stacks/etl/meet/connector_test.rb`

**Interfaces:**
- Consumes: `Meet::Connector.new(mode: :gemini_notes).run(track: false)`, all of Tasks 1–4.
- Produces: proof that a combined doc lands as a chunked `meet` transcript + a `gemini_notes` notes doc on ONE Meeting, that a 1:1 combined doc is walled on BOTH docs by the speaker head-count, and that an empty-transcript combined doc is notes-only.

- [ ] **Step 1: Write the ingest test**

Add to `test/lib/stacks/etl/meet/connector_test.rb`:
```ruby
  test "combined doc ingests as a meet transcript + gemini_notes doc on one meeting; 1:1 walled by speakers" do
    skip_without_pgvector
    group = OpenStruct.new(id: "N_GROUP", name: "Roadmap - 2026/06/30 15:00 EDT - Notes by Gemini", created_time: "2026-06-30T15:00:00Z")
    group_md = "# 📝 Notes\n\n## Roadmap\n\nInvited [A](mailto:a@x.co) [B](mailto:b@x.co) [C](mailto:c@x.co)\n\nMeeting records [Transcript](https://docs.google.com/document/d/N_GROUP/edit)\n\n### Summary\nShip the gateway.\n\n# 📖 Transcript\n\nAlice: kickoff\nBob: agreed\nCarol: shipping\n"
    oneone = OpenStruct.new(id: "N_11", name: "Kyle & Hugh - 2026/06/30 16:00 EDT - Notes by Gemini", created_time: "2026-06-30T16:00:00Z")
    # Two people INVITED plus a 3rd invitee, but only TWO actually speak -> 1:1 by real attendance.
    oneone_md = "# 📝 Notes\n\n## Kyle & Hugh\n\nInvited [K](mailto:k@x.co) [H](mailto:h@x.co) [X](mailto:x@x.co)\n\nMeeting records [Transcript](https://docs.google.com/document/d/N_11/edit)\n\n### Summary\nSensitive.\n\n# 📖 Transcript\n\nKyle: hey\nHugh: hi\n"

    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [group, oneone], next_page_token: nil))
    svc.stubs(:export_file).with("N_GROUP", "text/markdown").returns(group_md)
    svc.stubs(:export_file).with("N_11", "text/markdown").returns(oneone_md)
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    Stacks::Etl::Meet::Connector.new(admin_email: "hugh@sanctuary.computer", mode: :gemini_notes).run(track: false)

    tx = Document.find_by!(source: :meet, external_id: "N_GROUP")
    notes = Document.find_by!(source: :gemini_notes, external_id: "N_GROUP")
    assert tx.not_excluded?
    assert notes.not_excluded?
    assert tx.chunks.any?, "transcript chunked/searchable"
    assert notes.chunks.any?, "notes chunked/searchable"
    assert_equal tx.source_record_id, notes.source_record_id, "same Meeting"
    assert_equal ["a@x.co", "b@x.co", "c@x.co"], tx.document_contacts.pluck(:email).sort

    tx11 = Document.find_by!(source: :meet, external_id: "N_11")
    notes11 = Document.find_by!(source: :gemini_notes, external_id: "N_11")
    assert tx11.auto_excluded?, "2 real speakers -> 1:1 excluded despite 3 invited"
    assert tx11.reason_one_on_one?
    assert notes11.auto_excluded?, "notes inherit the 1:1 exclusion"
    assert_equal 0, tx11.chunks.count
    assert_equal 0, notes11.chunks.count
  end
```

- [ ] **Step 2: Run → PASS**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && bin/rails test test/lib/stacks/etl/meet/connector_test.rb -n /combined doc ingests/`
Expected: PASS (locally pgvector is available so it runs; on CI it skips via `skip_without_pgvector`). Debug until green — do NOT change production behavior to force it; if a real bug surfaces, fix the offending task's code.

- [ ] **Step 3: Full ETL + MCP suite (both paths)**

Run: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && bin/rails test test/lib/stacks/etl test/services/mcp test/lib/tasks/etl_rake_test.rb`
Then CI-mirror: `cd /Users/hhff/Documents/Code/stacks/.claude/worktrees/mcp-followups && DISABLE_PGVECTOR=1 bin/rails test test/lib/stacks/etl test/services/mcp test/lib/tasks/etl_rake_test.rb`
Expected: both green (the CI-mirror skips the embedding-touching tests).

- [ ] **Step 4: Commit**

```bash
git add test/lib/stacks/etl/meet/connector_test.rb
git commit -m "E2E: combined doc -> meet transcript + gemini_notes on one meeting, 1:1 walled by speakers"
```

---

### Task 6: Document the retroactive re-processing runbook step

**Files:**
- Modify: `docs/meet-etl-deploy.md` (the deploy runbook)

**Interfaces:** none (documentation).

- [ ] **Step 1: Add the runbook section**

Append to `docs/meet-etl-deploy.md` a section titled "Retroactive: split already-ingested combined Notes+Transcript docs", containing exactly:

> After this change is deployed, the combined "Notes by Gemini" docs ingested before it are single `gemini_notes` Documents on standalone `gemini_notes` Meetings, classified on invited count. One-time cleanup, then a re-run splits them correctly (idempotent):
>
> 1. Delete the combined-format notes Documents (self-referencing transcript link) and their now-orphaned meetings, via a one-off dyno:
>    ```
>    heroku run --size standard-1x --app g3d-stacks --no-tty "rails runner -" <<'RUBY'
>    combined = Document.where(source: :gemini_notes)
>                       .where("raw_metadata->>'transcript_doc_id' = external_id")
>    puts "combined notes docs to delete: #{combined.count}"
>    combined.find_each(&:destroy!)                       # cascades chunks/embeddings/document_contacts
>    orphans = Meeting.where(meet_source: :gemini_notes).left_joins(:documents).where(documents: { id: nil })
>    puts "orphaned gemini_notes meetings to delete: #{orphans.count}"
>    orphans.find_each(&:destroy!)                        # ONLY meetings left with zero Documents
>    RUBY
>    ```
>    This preserves legitimate notes-only meetings (transcription genuinely off): their notes doc has a `NULL` transcript_doc_id, so it is not deleted and its meeting keeps a Document.
> 2. Re-run the org-wide backfill (transcripts first, then notes; combined docs now split):
>    ```
>    heroku run:detached --size performance-l --app g3d-stacks "rake stacks:etl:backfill_meet_all[365]"
>    ```
> 3. Verify: `Document.where(source: :meet).count` rises (embedded transcripts now land as `meet`), combined `gemini_notes` docs now have a sibling `meet` doc on the same Meeting, and `chunks` on excluded docs stays 0.

- [ ] **Step 2: Commit**

```bash
git add docs/meet-etl-deploy.md
git commit -m "Runbook: retroactive split of combined Notes+Transcript docs (wipe + re-run)"
```

---

## Self-Review

**Spec coverage:**
- Detection (self-link) → Task 3 ✓; split at transcript heading (emoji-tolerant) → Task 3 ✓.
- Two records, transcript-first, meet + gemini_notes on one Meeting → Task 4 ✓.
- Speaker-based head-count for the transcript; notes inherit → Task 2 (ingest-time inherit) + Task 4 (speaker count) + Task 5 (e2e wall) ✓.
- Empty-transcript → notes-only → Task 4 ✓.
- Reverse-dedup defers to existing transcript Document → Task 4 ✓.
- Attribution reuses Invited emails → Task 4 `transcript_record`/`note_record` ✓.
- Shared parser extraction, DriveSource unchanged → Task 1 ✓.
- Retroactive wipe (self-ref docs + zero-Document gemini_notes meetings) + re-run → Task 6 ✓.
- Privacy wall proven by ingestion → Task 5 ✓.

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands are exact.

**Type consistency:** `combined_format?(text, file_id)`, `split_transcript(text) -> [notes_md, transcript_md]`, `records_for(file) -> Array`, `transcript_record`/`note_record` return normalized hashes with the same keys the base `Connector#ingest` consumes (`source`, `external_id`, `title`, `url`, `occurred_at`, `content_hash`, `contacts`, `segments`, `build_source_record`, plus `participant_count`/`transcript_doc_id`). `transcript_doc_id` is produced by `note_record` (Task 4) and consumed by `Connector#exclusion_for` + `build_meeting` (Task 2). `parse_segments`/`distinct_speaker_count` produced in Task 1, consumed in Task 4. Consistent throughout.
