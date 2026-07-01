# Gemini Notes Ingestion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ingest Google Meet "Notes by Gemini" Drive docs into the org vector corpus as a search-only, progressive-enhancement source alongside Meet transcripts, subject to the same privacy exclusion wall.

**Architecture:** Notes are treated as "another source" reusing the existing Document → Chunk → Embedding → MCP pipeline. A new `GeminiNotesSource` (parallel to `DriveSource`) queries Drive for notes docs, parses them, and yields normalized docs with `source: :gemini_notes` that link to the transcript's `Meeting` (or stand alone). Transcripts are untouched and remain load-bearing.

**Tech Stack:** Rails 6.1, Ruby 3.1, Minitest + mocha (no WebMock — stub Drive/Calendar via mocha), PostgreSQL + pgvector (`neighbor`), `google-apis-drive_v3`.

## Global Constraints

- Progressive enhancement: transcripts remain primary. Search/attribution/exclusion MUST work without notes. Nothing may require notes to exist.
- Search-only this increment. Do NOT parse Next-steps/Decisions into structured records (that is spec #2).
- Notes inherit their meeting's exclusion decision EXACTLY (a 1:1's notes are excluded like its transcript). Joined notes copy the transcript Document's `excluded`/`excluded_reason` verbatim; standalone notes classify via `Classifier(title:, participant_count:)`.
- Notes are Drive-only (no Meet API); deduped by the notes Drive doc id alone; no `until_time` overlap guard.
- Transcripts are swept BEFORE notes in every entry point so the join target exists.
- `db/schema.rb` hand-manages pgvector/content_tsv omissions — after any `db:migrate`, strip re-added `enable_extension "vector"`, `t.vector "embedding"` + its hnsw index, and the `content_tsv` column (see the comments in schema.rb). CI uses in-dyno Postgres; tests that create `Embedding` rows must call `skip_without_pgvector` in setup.
- Contact provenance tag stays `etl:meet` for notes (same pipeline).

## File Structure

- **Create** `lib/stacks/etl/meet/drive_doc.rb` — shared module: `clean_title`, date-stamp regexes, `coerce` (extracted from `DriveSource`; included by both sources).
- **Create** `lib/stacks/etl/meet/gemini_notes_source.rb` — `Stacks::Etl::Meet::GeminiNotesSource`: Drive query for notes docs, parse, `each_meeting`, `normalize`, `build_meeting`, join.
- **Create** `db/migrate/20260701000001_add_gemini_notes_doc_id_to_meetings.rb`.
- **Modify** `app/models/document.rb` (source enum), `app/models/chunk.rb` (source enum), `app/models/meeting.rb` (meet_source enum + `has_many :documents`).
- **Modify** `lib/stacks/etl/connector.rb` (Document + Chunk source from `normalized[:source]`).
- **Modify** `lib/stacks/etl/meet/connector.rb` (`:gemini_notes` mode + inherit-exclusion in `exclusion_for`).
- **Modify** `lib/stacks/etl/meet/drive_source.rb` (use the shared `DriveDoc` module).
- **Modify** `lib/stacks/etl/meet.rb` (allow `mode: :gemini_notes` — already generic).
- **Modify** `lib/tasks/etl.rake` (`sync_all` + `backfill_meet_all` run a notes sweep after transcripts).
- **Tests** under `test/lib/stacks/etl/meet/` and `test/lib/stacks/etl/`.

---

### Task 1: Schema + model enums

**Files:**
- Create: `db/migrate/20260701000001_add_gemini_notes_doc_id_to_meetings.rb`
- Modify: `app/models/document.rb`, `app/models/chunk.rb`, `app/models/meeting.rb`, `db/schema.rb`
- Test: `test/models/meeting_test.rb` (create if absent)

**Interfaces:**
- Produces: `Document.sources["gemini_notes"] == 1`, `Chunk.sources["gemini_notes"] == 1`, `Meeting.meet_sources["gemini_notes"] == 2`, `meetings.gemini_notes_doc_id` (string, unique-where-not-null), `Meeting#documents` (has_many, polymorphic `source_record`).

- [ ] **Step 1: Write the migration**

```ruby
# db/migrate/20260701000001_add_gemini_notes_doc_id_to_meetings.rb
class AddGeminiNotesDocIdToMeetings < ActiveRecord::Migration[6.1]
  def change
    add_column :meetings, :gemini_notes_doc_id, :string
    add_index :meetings, :gemini_notes_doc_id, unique: true,
              where: "gemini_notes_doc_id IS NOT NULL",
              name: "index_meetings_on_gemini_notes_doc_id"
  end
end
```

- [ ] **Step 2: Run the migration + fix schema.rb by hand**

Run: `RAILS_ENV=test bundle exec rake db:migrate` then `git diff db/schema.rb`.
Expected: schema.rb gains `t.string "gemini_notes_doc_id"` + its index AND regenerates the pgvector/content_tsv/composite-FK lines. **Manually revert** everything except the version bump + the two new gemini_notes_doc_id lines (restore the `# … intentionally omitted here` comment block for content_tsv/vector, the composite-FK comments, and drop the re-added `t.vector`/`enable_extension "vector"`/hnsw index). Verify with `RAILS_ENV=test bundle exec rake db:schema:load` — no error.

- [ ] **Step 3: Add the enum values + association**

```ruby
# app/models/document.rb — change the source enum line to:
  enum source: { meet: 0, gemini_notes: 1 }
# app/models/chunk.rb — change:
  enum source: { meet: 0, gemini_notes: 1 }
# app/models/meeting.rb — change the has_one + enum:
  has_many :documents, as: :source_record
  enum meet_source: { meet_api: 0, drive: 1, gemini_notes: 2 }
```

- [ ] **Step 4: Find and fix any `meeting.document` (singular) callers**

Run: `grep -rn "\.document\b" app lib | grep -iE "meeting" ` and `grep -rn "source_record" app/admin`.
For each caller of the old `has_one :document` (e.g. an admin show page), replace `meeting.document` with `meeting.documents.find_by(source: :meet)` (the transcript) or `meeting.documents.first`. If none exist, note it and continue.

- [ ] **Step 5: Test the enums + association**

```ruby
# test/models/meeting_test.rb
require "test_helper"
class MeetingTest < ActiveSupport::TestCase
  test "a meeting can own a transcript and a notes document" do
    m = Meeting.create!(meet_source: :drive, drive_transcript_doc_id: "t1")
    t = Document.create!(source: :meet, external_id: "t1", source_record: m)
    n = Document.create!(source: :gemini_notes, external_id: "n1", source_record: m)
    assert_equal [t.id, n.id].sort, m.documents.pluck(:id).sort
    assert_equal 1, Document.sources["gemini_notes"]
    assert_equal 1, Chunk.sources["gemini_notes"]
    assert_equal 2, Meeting.meet_sources["gemini_notes"]
  end
end
```

- [ ] **Step 6: Run + commit**

Run: `bundle exec rails test test/models/meeting_test.rb` → PASS.
`git add -A && git commit -m "Gemini notes: schema + source/meet_source enums + Meeting has_many documents"`

---

### Task 2: Shared `DriveDoc` module (extract from DriveSource)

**Files:**
- Create: `lib/stacks/etl/meet/drive_doc.rb`
- Modify: `lib/stacks/etl/meet/drive_source.rb`
- Test: existing `test/lib/stacks/etl/meet/drive_source_test.rb` must still pass (behavior preserved).

**Interfaces:**
- Produces: `Stacks::Etl::Meet::DriveDoc` module with private-style methods `clean_title(name)` (strips a trailing `- Transcript` OR ` - Notes by Gemini` suffix AND the paren/dash date stamps) and `coerce(t)`. Included by `DriveSource` and (Task 3) `GeminiNotesSource`.

- [ ] **Step 1: Create the shared module** (move the regexes + methods out of `DriveSource`, generalizing the suffix)

```ruby
# lib/stacks/etl/meet/drive_doc.rb
module Stacks
  module Etl
    module Meet
      # Shared helpers for Google Meet Drive Docs (transcripts + Gemini notes), whose
      # names share the same "<Title> - <date> <tz> - <Kind>" shape.
      module DriveDoc
        # Strips the "- Transcript" / " - Notes by Gemini" suffix, then Meet's date stamp
        # in either the parenthetical "(2026/06/27 17:00 GMT-7)" or dash
        # "- 2026/06/22 17:15 EDT" form. Requires a real date + clock time so a normal title
        # like "Planning - Q3" or "Retro (5:00 format)" survives.
        SUFFIX = /\s*-\s*(?:Transcript|Notes by Gemini)\s*\z/i
        PAREN_DATE_STAMP = %r{\s*\((?:\d{2,4}[/-]\d{1,2}[/-]\d{1,2}|[^)]*\bGMT\b)[^)]*\)\s*\z}
        DASH_DATE_STAMP  = %r{\s*-\s*\d{2,4}[/-]\d{1,2}[/-]\d{1,2}\s+\d{1,2}:\d{2}(?:\s*[AP]M)?(?:\s+[A-Za-z0-9+\-]{2,6})?\s*\z}i

        def clean_title(name)
          name.to_s.sub(SUFFIX, "").sub(PAREN_DATE_STAMP, "").sub(DASH_DATE_STAMP, "").strip.presence || name.to_s
        end

        def coerce(t)
          return nil if t.nil?
          t.is_a?(String) ? Time.parse(t) : t
        end
      end
    end
  end
end
```

- [ ] **Step 2: Use it in DriveSource; delete the duplicated code**

In `lib/stacks/etl/meet/drive_source.rb`: add `include DriveDoc` to the class, and **delete** the now-duplicated `clean_title`, `PAREN_DATE_STAMP`, `DASH_DATE_STAMP`, and `coerce` definitions. Add `require_relative "drive_doc"` if the app's autoloading needs it (it should not — Zeitwerk resolves `Stacks::Etl::Meet::DriveDoc` from the path).

- [ ] **Step 3: Run the existing drive_source tests**

Run: `bundle exec rails test test/lib/stacks/etl/meet/drive_source_test.rb`
Expected: PASS unchanged (clean_title dash/paren cases, coerce). If the `- Notes by Gemini` generalization changed any transcript case, it should not (transcripts never carry that suffix).

- [ ] **Step 4: Commit**

`git add -A && git commit -m "Extract shared DriveDoc (clean_title/date-stamps/coerce) from DriveSource"`

---

### Task 3: `GeminiNotesSource` parser (pure parsing of an exported notes doc)

**Files:**
- Create: `lib/stacks/etl/meet/gemini_notes_source.rb`
- Test: `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`

**Interfaces:**
- Produces: `Stacks::Etl::Meet::GeminiNotesSource` with private parse helpers, unit-testable via `allocate` + `send`:
  - `transcript_doc_id_from(text) -> String|nil` (the `/document/d/<id>` in the `[Transcript](…)` line)
  - `invited_emails_from(text) -> [String]` (lowercased `mailto:` emails, room resources skipped)
  - `body_segments(text, occurred_at:) -> [{ speaker_name: nil, speaker_email: nil, text:, started_at: }]`

- [ ] **Step 1: Write the parser tests**

```ruby
# test/lib/stacks/etl/meet/gemini_notes_source_test.rb
require "test_helper"
class Stacks::Etl::Meet::GeminiNotesSourceTest < ActiveSupport::TestCase
  SAMPLE = <<~TXT
    Notes

    ## Sync Title

    Invited [Ayaka Takao](mailto:Ayaka@Index-Space.org) [Hugh Francis](mailto:hugh@sanctuary.computer) [Room](mailto:room@resource.calendar.google.com)

    Meeting records [Transcript](https://docs.google.com/document/d/TRANSCRIPT_ID_123/edit?usp=drive_web)

    ### Summary
    We decided to ship the gateway redesign.

    ### Next steps
    - [Hugh Francis] Finish Slides: Complete the case study slides.
  TXT

  def src = Stacks::Etl::Meet::GeminiNotesSource.allocate

  test "extracts the transcript doc id from the Transcript link" do
    assert_equal "TRANSCRIPT_ID_123", src.send(:transcript_doc_id_from, SAMPLE)
    assert_nil src.send(:transcript_doc_id_from, "no link here")
  end

  test "extracts invited emails (lowercased), skipping room resources" do
    assert_equal ["ayaka@index-space.org", "hugh@sanctuary.computer"],
                 src.send(:invited_emails_from, SAMPLE)
  end

  test "body segments carry the notes text with the meeting time and no speaker" do
    at = Time.utc(2026, 6, 30, 15)
    segs = src.send(:body_segments, SAMPLE, occurred_at: at)
    assert segs.any?
    joined = segs.map { |s| s[:text] }.join(" ")
    assert_includes joined, "ship the gateway redesign"
    assert_includes joined, "Finish Slides"
    assert_nil segs.first[:speaker_name]
    assert_equal at, segs.first[:started_at]
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run: `bundle exec rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb`
Expected: FAIL (`uninitialized constant … GeminiNotesSource`).

- [ ] **Step 3: Implement the class shell + parsers**

```ruby
# lib/stacks/etl/meet/gemini_notes_source.rb
require "digest"
module Stacks
  module Etl
    module Meet
      class GeminiNotesSource
        include DriveDoc
        QUERY = "mimeType='application/vnd.google-apps.document' and name contains 'Notes by Gemini'".freeze

        def initialize(user_email, since:, until_time: nil)
          @user_email = user_email
          @since = coerce(since)
          @until_time = coerce(until_time) # notes have no overlap guard; callers pass nil
          @service = Auth.drive_service(sub: user_email)
        end

        private

        def transcript_doc_id_from(text)
          # The "Meeting records [Transcript](…/document/d/<id>/…)" line.
          m = text.to_s.match(%r{\[Transcript\]\(https://docs\.google\.com/document/d/([A-Za-z0-9_-]+)})
          m && m[1]
        end

        def invited_emails_from(text)
          # Emails only appear as mailto: links, primarily in the "Invited" block.
          text.to_s.scan(/mailto:([^)\s]+)/).flatten.map { |e| e.downcase }
              .reject { |e| e.end_with?("resource.calendar.google.com") }.uniq
        end

        def body_segments(text, occurred_at:)
          # Search-only: the whole notes body IS the searchable content. Split into
          # paragraph-ish blocks so the Chunker has natural boundaries; drop the trailing
          # Gemini feedback/footer noise.
          cleaned = text.to_s.gsub(/We've updated the Decisions section.*\z/m, "")
                        .gsub(/Let us know what you think.*\z/m, "")
                        .gsub(/You should review Gemini's notes.*\z/m, "")
          cleaned.split(/\n{2,}/).map(&:strip).reject(&:empty?).map do |para|
            { speaker_name: nil, speaker_email: nil, text: para, started_at: occurred_at, ended_at: nil }
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify pass**

Run: `bundle exec rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb` → PASS.

- [ ] **Step 5: Commit**

`git add -A && git commit -m "GeminiNotesSource: parse transcript link, invited emails, body segments"`

---

### Task 4: Base Connector — Document/Chunk source from `normalized[:source]`

**Files:**
- Modify: `lib/stacks/etl/connector.rb`
- Test: `test/lib/stacks/etl/connector_test.rb`

**Interfaces:**
- Produces: `Connector#ingest` keys the Document on `normalized[:source] || source`, and `index_chunks!` already sets `chunk.source = document.source`, so a normalized doc carrying `source: :gemini_notes` becomes a `gemini_notes` Document + chunks. Default (no `:source` key) is unchanged (`:meet`).

- [ ] **Step 1: Add the failing test** (append to `connector_test.rb`; the class has `FakeConnector` with `source = :meet` and stubs Embedder)

```ruby
  test "a normalized doc can override the source (e.g. gemini_notes)" do
    n = normalized(external_id: "gn1", hash: "h").merge(source: :gemini_notes)
    FakeConnector.new([n]).run
    doc = Document.find_by!(external_id: "gn1")
    assert doc.gemini_notes?
    assert doc.chunks.all?(&:gemini_notes?)
  end
```

- [ ] **Step 2: Run → FAIL** (`doc.gemini_notes?` false — it was created as `:meet`).

Run: `bundle exec rails test test/lib/stacks/etl/connector_test.rb -n /override the source/`

- [ ] **Step 3: Implement** — in `lib/stacks/etl/connector.rb`, `ingest`, change the find line:

```ruby
        doc = Document.find_or_initialize_by(source: normalized[:source] || source, external_id: normalized[:external_id])
```

(No other change — `index_chunks!` already does `source: document.source`.)

- [ ] **Step 4: Run → PASS**, and run the whole file to confirm no regressions:

Run: `bundle exec rails test test/lib/stacks/etl/connector_test.rb` → all PASS.

- [ ] **Step 5: Commit**

`git add -A && git commit -m "Connector: allow a normalized doc to set its own source"`

---

### Task 5: `GeminiNotesSource#each_meeting` + normalize + join + exclusion inheritance

**Files:**
- Modify: `lib/stacks/etl/meet/gemini_notes_source.rb`, `lib/stacks/etl/meet/connector.rb`
- Test: `test/lib/stacks/etl/meet/gemini_notes_source_test.rb`

**Interfaces:**
- Consumes: `DriveDoc#clean_title`, the parsers from Task 3, `Document.find_by(source: :meet, external_id:)`, `Classifier`, `Connector#run`.
- Produces: `GeminiNotesSource#each_meeting { |normalized| }` yielding, per notes doc, a hash with `source: :gemini_notes`, `external_id: <notes file id>`, `title`, `occurred_at`, `content_hash`, `contacts` (invited emails, role "attendee"), `segments` (body), plus EITHER `inherit_exclusion: [excluded_sym, reason_sym]` (joined) OR `participant_count:` (standalone), and `build_source_record` linking the notes Document to the transcript's Meeting or a standalone `gemini_notes` Meeting. `Meet::Connector.new(mode: :gemini_notes)` runs it; `Meet::Connector#exclusion_for` honors `inherit_exclusion`.

- [ ] **Step 1: Write the each_meeting/join tests** (mocha-stub Drive + Auth)

```ruby
  test "joins a notes doc to the existing transcript's meeting and inherits its exclusion" do
    meeting = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/1")
    Document.create!(source: :meet, external_id: "TRANSCRIPT_ID_123", source_record: meeting,
                     excluded: :auto_excluded, excluded_reason: :one_on_one)
    file = OpenStruct.new(id: "notesfile1", name: "Sync Title - 2026/06/30 15:00 EDT - Notes by Gemini",
                          created_time: "2026-06-30T15:00:00Z")
    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns(SAMPLE) # from Task 3, contains TRANSCRIPT_ID_123
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    n = nil
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |x| n = x }
    assert_equal :gemini_notes, n[:source]
    assert_equal "notesfile1", n[:external_id]
    assert_equal "Sync Title", n[:title]
    assert_equal [:auto_excluded, :one_on_one], n[:inherit_exclusion]
    assert_equal ["ayaka@index-space.org", "hugh@sanctuary.computer"], n[:contacts].map { |c| c[:email] }
    doc = Document.create!(source: :gemini_notes, external_id: "notesfile1")
    built = n[:build_source_record].call(doc)
    assert_equal meeting.id, built.id # linked to the SAME meeting
  end

  test "a notes doc with no known transcript is standalone with its own classification" do
    file = OpenStruct.new(id: "notesfile2", name: "Team Weekly - 2026/06/30 15:00 EDT - Notes by Gemini",
                          created_time: "2026-06-30T15:00:00Z")
    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns("Notes\n\n## Team Weekly\n\nInvited [A](mailto:a@x.co) [B](mailto:b@x.co) [C](mailto:c@x.co)\n\n### Summary\nStuff happened.")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)
    n = nil
    Stacks::Etl::Meet::GeminiNotesSource.new("hugh@sanctuary.computer", since: Time.utc(2025, 1, 1)).each_meeting { |x| n = x }
    assert_nil n[:inherit_exclusion]
    assert_equal 3, n[:participant_count] # invited count -> classifier sees a group
    doc = Document.create!(source: :gemini_notes, external_id: "notesfile2")
    built = n[:build_source_record].call(doc)
    assert_equal "notesfile2", built.gemini_notes_doc_id
    assert built.gemini_notes?
  end
```

- [ ] **Step 2: Run → FAIL** (`each_meeting` undefined).

- [ ] **Step 3: Implement `each_meeting` + `normalize` + `build_meeting`** in `gemini_notes_source.rb`

```ruby
        def each_meeting
          page = nil
          loop do
            q = "#{QUERY} and createdTime > '#{@since.utc.iso8601}'"
            q += " and createdTime < '#{@until_time.utc.iso8601}'" if @until_time
            resp = @service.list_files(q: q, fields: "nextPageToken, files(id,name,createdTime)", page_token: page)
            Array(resp.files).each { |f| yield normalize(f) }
            page = resp.next_page_token
            break unless page
          end
        end

        private

        def normalize(file)
          text = @service.export_file(file.id, "text/plain")
          title = clean_title(file.name)
          occurred_at = coerce(file.created_time)
          transcript_id = transcript_doc_id_from(text)
          emails = invited_emails_from(text)
          segments = body_segments(text, occurred_at: occurred_at)

          # Join to the transcript's meeting when we ingested that transcript.
          transcript_doc = transcript_id && Document.find_by(source: :meet, external_id: transcript_id)
          meeting = transcript_doc&.source_record

          base = {
            source: :gemini_notes,
            external_id: file.id,
            title: title,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: occurred_at,
            content_hash: Digest::SHA256.hexdigest(text.to_s),
            contacts: emails.map { |e| { email: e, name: nil, role: "attendee" } },
            segments: segments,
            raw_metadata: { "gemini_notes_doc_id" => file.id, "transcript_doc_id" => transcript_id },
            build_source_record: ->(doc) { build_meeting(doc, file, title, occurred_at, meeting) }
          }
          if meeting && transcript_doc
            # Inherit the transcript's decision verbatim (identical privacy wall).
            base.merge(inherit_exclusion: [transcript_doc.excluded.to_sym, transcript_doc.excluded_reason.to_sym])
          else
            base.merge(participant_count: emails.size) # standalone -> classify on invited count
          end
        end

        def build_meeting(doc, file, title, occurred_at, joined_meeting)
          meeting = joined_meeting || Meeting.find_or_initialize_by(gemini_notes_doc_id: file.id)
          meeting.update!(meet_source: (joined_meeting ? meeting.meet_source : :gemini_notes),
                          title: title, started_at: occurred_at,
                          gemini_notes_doc_id: file.id,
                          raw_metadata: (meeting.raw_metadata || {}).merge("gemini_notes_document_id" => doc.id))
          meeting
        end
```

- [ ] **Step 4: Honor `inherit_exclusion` in `Meet::Connector#exclusion_for`** (`lib/stacks/etl/meet/connector.rb`)

```ruby
        def exclusion_for(normalized)
          return normalized[:inherit_exclusion] if normalized[:inherit_exclusion]
          count = normalized[:participant_count] || normalized[:contacts].size
          Classifier.call(title: normalized[:title], participant_count: count)
        end
```

- [ ] **Step 5: Add the `:gemini_notes` mode to `Meet::Connector#source_object`**

```ruby
        def source_object(since)
          case @mode
          when :drive        then DriveSource.new(@admin_email, since: since || 90.days.ago, until_time: @until_time)
          when :gemini_notes then GeminiNotesSource.new(@admin_email, since: since || 90.days.ago, until_time: @until_time)
          else MeetApiSource.new(@admin_email, since: since)
          end
        end
```

- [ ] **Step 6: Run → PASS**

Run: `bundle exec rails test test/lib/stacks/etl/meet/gemini_notes_source_test.rb` → PASS.

- [ ] **Step 7: Commit**

`git add -A && git commit -m "GeminiNotesSource: each_meeting, join to transcript meeting, exclusion inheritance"`

---

### Task 6: End-to-end connector ingest of notes (exclusion + attribution + search)

**Files:**
- Test: `test/lib/stacks/etl/meet/connector_test.rb`

**Interfaces:**
- Consumes: `Meet::Connector.new(mode: :gemini_notes)`, everything from Tasks 3–5.
- Produces: proof that a joined notes doc is ingested as a `gemini_notes` Document, chunked+embedded when its meeting is eligible, and left unchunked (walled) when the meeting is a 1:1; and that invited emails land on `document_contacts`.

- [ ] **Step 1: Write the ingest tests** (stub Drive + Auth; `setup` already stubs `Embedder.embed`; add `skip_without_pgvector` since ingest creates embeddings)

```ruby
  test "notes for an eligible meeting are ingested, chunked, and searchable; a 1:1's notes are walled off" do
    skip_without_pgvector
    # Eligible transcript meeting + a 1:1 transcript meeting already ingested:
    ok_m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/ok")
    Document.create!(source: :meet, external_id: "T_OK", source_record: ok_m, excluded: :not_excluded, excluded_reason: :none)
    oo_m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/oo")
    Document.create!(source: :meet, external_id: "T_OO", source_record: oo_m, excluded: :auto_excluded, excluded_reason: :one_on_one)

    files = [
      OpenStruct.new(id: "N_OK", name: "Roadmap - 2026/06/30 15:00 EDT - Notes by Gemini", created_time: "2026-06-30T15:00:00Z"),
      OpenStruct.new(id: "N_OO", name: "1:1 - 2026/06/30 16:00 EDT - Notes by Gemini", created_time: "2026-06-30T16:00:00Z")
    ]
    svc = mock("drive")
    svc.stubs(:list_files).returns(OpenStruct.new(files: files, next_page_token: nil))
    svc.stubs(:export_file).with("N_OK", "text/plain").returns("Notes\n\nInvited [A](mailto:a@x.co)\n\nMeeting records [Transcript](https://docs.google.com/document/d/T_OK/edit)\n\n### Summary\nShip the gateway.")
    svc.stubs(:export_file).with("N_OO", "text/plain").returns("Notes\n\nMeeting records [Transcript](https://docs.google.com/document/d/T_OO/edit)\n\n### Summary\nSensitive 1:1 content.")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    Stacks::Etl::Meet::Connector.new(admin_email: "hugh@sanctuary.computer", mode: :gemini_notes).run(track: false)

    ok = Document.find_by!(source: :gemini_notes, external_id: "N_OK")
    assert ok.not_excluded?
    assert ok.chunks.any?, "eligible notes should be chunked/searchable"
    assert_equal ["a@x.co"], ok.document_contacts.pluck(:email)
    assert_equal ok_m.id, ok.source_record_id

    oo = Document.find_by!(source: :gemini_notes, external_id: "N_OO")
    assert oo.auto_excluded?
    assert oo.reason_one_on_one?
    assert_equal 0, oo.chunks.count, "a 1:1's notes must be walled off"
  end
```

- [ ] **Step 2: Run → PASS** (all wiring from Tasks 3–5 should carry it). Debug until green.

Run: `bundle exec rails test test/lib/stacks/etl/meet/connector_test.rb -n /notes for an eligible/`

- [ ] **Step 3: Commit**

`git add -A && git commit -m "Notes ingest: eligible notes chunked+searchable, 1:1 notes walled, invited emails attributed"`

---

### Task 7: Wire notes sweeps into `sync_all` + `backfill_meet_all` (transcripts first)

**Files:**
- Modify: `lib/tasks/etl.rake`
- Test: `test/lib/stacks/etl/meet/sweep_test.rb` (or wherever `sweep_all_users!` is tested)

**Interfaces:**
- Consumes: `Stacks::Etl::Meet.sweep_all_users!(task_name:, mode:, since:, until_time:)` (already generic over `mode`), `Meet::Connector` `:gemini_notes` mode.
- Produces: `sync_all` runs the API transcript sweep THEN a `:gemini_notes` Drive sweep over the recent window; `backfill_meet_all[N]` runs the Drive transcript sweep THEN a `:gemini_notes` sweep over the historical window (both with `until_time: nil` for notes — no overlap guard).

- [ ] **Step 1: Test the ordering + that notes get their own sweep** (mocha: expect `sweep_all_users!` called with `mode: :api`/`:drive` then `mode: :gemini_notes`, in order)

```ruby
  test "backfill_meet_all sweeps transcripts, then a gemini_notes sweep (no until_time)" do
    seq = sequence("sweeps")
    Stacks::Etl::Meet.expects(:sweep_all_users!).with(has_entry(mode: :drive)).in_sequence(seq)
    Stacks::Etl::Meet.expects(:sweep_all_users!).with(has_entries(mode: :gemini_notes, until_time: nil)).in_sequence(seq)
    Rake::Task["stacks:etl:backfill_meet_all"].reenable
    Rake::Task["stacks:etl:backfill_meet_all"].invoke("30")
  end
```

- [ ] **Step 2: Run → FAIL** (only one sweep today).

- [ ] **Step 3: Implement** in `lib/tasks/etl.rake` — after the existing transcript sweeps, add the notes sweep:

```ruby
    # inside backfill_meet_all, AFTER the Drive transcript sweep:
      Stacks::Etl::Meet.sweep_all_users!(
        task_name: "stacks:etl:backfill_gemini_notes_all",
        mode: :gemini_notes,
        since: (args[:days] || 90).to_i.days.ago,
        until_time: nil # notes are Drive-only; no API overlap to guard against
      )

    # replace sync_all's body with transcripts-then-notes:
    desc "Nightly ETL sync across ALL sources (currently Meet transcripts + Gemini notes)"
    task sync_all: :environment do
      %w[stacks:etl:sync_meet_all stacks:etl:sync_gemini_notes_all].each do |t|
        Rake::Task[t].invoke
      rescue => e
        Rails.logger.error("stacks:etl:sync_all — #{t} failed: #{e.class}: #{e.message}")
      end
    end

    desc "Org-wide Gemini-notes sync for ALL users (recent window; default 10 days)"
    task :sync_gemini_notes_all, [:days] => :environment do |_t, args|
      Stacks::Etl::Meet.sweep_all_users!(
        task_name: "stacks:etl:sync_gemini_notes_all",
        mode: :gemini_notes,
        since: (args[:days] || 10).to_i.days.ago,
        until_time: nil
      )
    end
```

- [ ] **Step 4: Run → PASS**; also run the full sweep test file.

Run: `bundle exec rails test test/lib/stacks/etl/meet/sweep_test.rb`

- [ ] **Step 5: Update the deploy runbook** — in `docs/meet-etl-deploy.md`, note that `sync_all` and `backfill_meet_all` now also sweep Gemini notes (Drive-only, recent + historical), one line.

- [ ] **Step 6: Commit**

`git add -A && git commit -m "Sweep Gemini notes in sync_all (recent) + backfill_meet_all (historical), after transcripts"`

---

### Task 8: MCP surface verification (notes searchable + source-filterable + walled)

**Files:**
- Test: `test/services/mcp/tools_test.rb`

**Interfaces:**
- Consumes: existing `Mcp::ListDocumentsTool`, `Mcp::SearchTool` (both already accept a `source` filter), the `gemini_notes` Document from prior tasks.
- Produces: proof that notes surface through the existing tools with no code change, are filterable by `source`, and excluded notes are hidden.

- [ ] **Step 1: Write the test** (no embeddings needed — keyword search on `content_tsv` + `list_documents`; CI-safe)

```ruby
  test "list_documents can filter to gemini_notes and hides excluded notes" do
    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: "cr/z")
    note = Document.create!(source: :gemini_notes, external_id: "gn", title: "Roadmap notes", excluded: :not_excluded, source_record: m)
    Document.create!(source: :gemini_notes, external_id: "gn2", title: "1:1 notes", excluded: :auto_excluded, source_record: m)

    resp = Mcp::ListDocumentsTool.call(source: "gemini_notes", server_context: {})
    ids = JSON.parse(resp.content.first[:text]).map { |d| d["id"] }
    assert_equal [note.id], ids
  end
```

- [ ] **Step 2: Run → PASS** (existing tools already support `source`; confirm the enum value flows through `Document.sources["gemini_notes"]`).

Run: `bundle exec rails test test/services/mcp/tools_test.rb -n /gemini_notes/`

- [ ] **Step 3: Full suite + CI-path check**

Run: `bundle exec rails test test/lib/stacks/etl test/services/mcp test/models/meeting_test.rb` → all PASS.
Run: `DISABLE_PGVECTOR=1 RAILS_ENV=test bundle exec rake db:schema:load && DISABLE_PGVECTOR=1 bundle exec rails test test/lib/stacks/etl test/services/mcp` → PASS with the embedding-touching notes tests skipped (mirrors CI). Then restore: `RAILS_ENV=test bundle exec rake db:schema:load`.

- [ ] **Step 4: Commit**

`git add -A && git commit -m "MCP: notes surface via existing search/list_documents, source-filterable, excluded walled"`

---

## Self-Review

- **Spec coverage:** enum/source (T1, T4) ✓; Meeting has_many (T1) ✓; GeminiNotesSource query+parse (T2, T3, T5) ✓; join via transcript link + standalone (T5) ✓; exclusion inheritance (T5, T6) ✓; invited-email supplement (T5, T6) ✓; chunk/embed body (T3 body_segments → T6) ✓; sweeps in sync_all + backfill, transcripts-first, no notes overlap guard (T7) ✓; MCP surface (T8) ✓; progressive-enhancement (transcripts untouched; notes optional) — no task modifies transcript ingestion ✓.
- **Type consistency:** `normalized[:source]` (T4) matches GeminiNotesSource output (T5); `inherit_exclusion: [sym, sym]` produced in T5 / consumed in T5 exclusion_for; `mode: :gemini_notes` used in T5 source_object + T7 sweeps; `gemini_notes_doc_id` column (T1) keyed in T5 build_meeting; `Meeting#documents` (T1) asserted in T1/T6.
- **Notes/edge:** joined-meeting update in T5 preserves `meet_source` for joined meetings (only standalone becomes `:gemini_notes`); body_segments strips Gemini footer noise; contacts role "attendee" matches the connector's `sync_document_contacts` shape.
