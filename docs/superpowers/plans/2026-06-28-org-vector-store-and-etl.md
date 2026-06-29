# Org-Wide Vector Store & ETL — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a durable, org-wide vector store fed by an ETL pipeline in the Stacks Rails app, with Google Meet transcripts as the first source, queryable by an agent through a read-only MCP server.

**Architecture:** A source-agnostic core (`documents → chunks`, a polymorphic `embeddings` side-table, `mentions`, `document_contacts`, `source_syncs`) sits under a connector/ETL framework (`Stacks::Etl::Connector`). The Meet connector (Meet REST API v2 for ongoing + Drive export for backfill) projects rich `meetings`/`segments`/`participants` into the core. Hybrid keyword+semantic search is exposed via the official `mcp` gem over Streamable HTTP. Identity is anchored on the existing `contacts` table.

**Tech Stack:** Rails 6.1, Ruby 3.1.7, PostgreSQL + pgvector (via `neighbor`), `google-apis-meet_v2`, `google-apis-drive_v3`, Voyage AI embeddings (HTTP via `httparty`), the `mcp` Ruby gem, ActiveAdmin, Minitest + `mocha`.

## Global Constraints

- **Ruby 3.1.7 / Rails 6.1** — pin gem versions that still support Ruby 3.1: `neighbor "~> 0.4.3"`, `google-apis-meet_v2 "0.13.0"`. For `google-apis-drive_v3` and `mcp`, pin the newest version whose gemspec `required_ruby_version` allows 3.1 (verify with `gem spec <gem> -v <version> required_ruby_version` or `bundle update` failing). Do **not** assume latest.
- **Heroku Postgres prerequisite:** pgvector is only on Standard/Premium/Private/Shield tiers (PG 15+, pgvector 0.8.0). The `vector` extension must be enabled (`CREATE EXTENSION vector;`). If the target DB is Essential/Mini, the deploy will fail — confirm tier before shipping.
- **Tests:** Minitest with `mocha/minitest`. No WebMock/VCR — stub external HTTP/service objects with mocha. Fixtures via `fixtures :all`. Run with `bin/rails test <path>` (single test: `bin/rails test <path> -n <name>`).
- **Config:** secrets via the existing `Stacks::Utils.config` mechanism (same as `config[:google_oauth2][:service_account]`). Add `config[:voyage][:api_key]` and `config[:mcp][:bearer_token]`.
- **Background work:** no job framework. Long-running work is rake tasks wrapped in a `SystemTask` record (`SystemTask.create!(name:)` → `mark_as_success` / `mark_as_error(e)`), scheduled by Heroku Scheduler — mirror `stacks:sync_forecast`.
- **Identity:** every person resolves to a `Contact` by email (`create_or_find_by`, lowercased, tag `sources` with `"meet"`). No `AdminUser`/`Contributor` reconciliation.
- **Exclusion:** corpus eligibility = `excluded IN (not_excluded, manually_included)`. Excluded documents get **no** chunks and **no** embeddings, and are never returned by MCP.
- **Embeddings:** model `voyage-3`, 1024 dims, cosine. Stored in the `embeddings` side-table, never as a column on `chunks`.
- Commit after every task. Conventional-commit messages.

---

## File Structure

```
db/migrate/                         # one migration per schema task
app/models/
  document.rb document_contact.rb chunk.rb mention.rb embedding.rb source_sync.rb
  meeting.rb meeting_participant.rb meeting_transcript_segment.rb
  contact.rb                        # MODIFY (display_name + meet source helper)
lib/stacks/etl/
  embedder.rb chunker.rb mention_resolver.rb connector.rb search.rb
  meet/auth.rb meet/classifier.rb meet/meet_api_source.rb meet/drive_source.rb meet/connector.rb
app/services/mcp/
  search_tool.rb list_documents_tool.rb get_document_tool.rb list_sources_tool.rb
  server.rb
app/controllers/api/mcp_controller.rb   # bearer auth + transport dispatch
app/admin/
  meeting.rb document.rb chunk.rb mention.rb source_sync.rb   # MCP menu → ETL subpages
lib/tasks/etl.rake
config/routes.rb                    # MODIFY (mount MCP under api ns)
test/...                            # mirror each unit
```

---

## Task 1: Dependencies + enable pgvector

**Files:**
- Modify: `Gemfile`
- Create: `db/migrate/<ts>_enable_vector_extension.rb`
- Test: `test/lib/pgvector_smoke_test.rb`

**Interfaces:**
- Produces: the `vector` Postgres type available; gems `neighbor`, `google-apis-meet_v2`, `google-apis-drive_v3`, `mcp` installed.

- [ ] **Step 1: Add gems**

In `Gemfile` (near the other `google-apis-*` gems):

```ruby
gem 'google-apis-meet_v2', '0.13.0'
gem 'google-apis-drive_v3'        # pin newest version whose gemspec allows Ruby 3.1
gem 'neighbor', '~> 0.4.3'
gem 'mcp'                          # pin newest version whose gemspec allows Ruby 3.1
```

- [ ] **Step 2: Install and pin**

Run: `bundle install`
Expected: resolves. If `google-apis-drive_v3` or `mcp` fail on `required_ruby_version`, append an explicit older version constraint and re-run until green. Record the resolved versions in `Gemfile.lock`.

- [ ] **Step 3: Write the extension migration**

```ruby
class EnableVectorExtension < ActiveRecord::Migration[6.1]
  def change
    enable_extension 'vector'
  end
end
```

- [ ] **Step 4: Migrate**

Run: `bin/rails db:migrate`
Expected: `db/schema.rb` gains `enable_extension "vector"`.

- [ ] **Step 5: Write the smoke test**

```ruby
require 'test_helper'

class PgvectorSmokeTest < ActiveSupport::TestCase
  test 'vector extension is enabled' do
    result = ActiveRecord::Base.connection.execute("SELECT 1 FROM pg_extension WHERE extname = 'vector'")
    assert_equal 1, result.ntuples
  end
end
```

- [ ] **Step 6: Run it**

Run: `bin/rails test test/lib/pgvector_smoke_test.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add Gemfile Gemfile.lock db/migrate db/schema.rb test/lib/pgvector_smoke_test.rb
git commit -m "feat(etl): add vector/google/mcp gems and enable pgvector"
```

---

## Task 2: Extend `contacts` as the identity spine

**Files:**
- Create: `db/migrate/<ts>_add_display_name_to_contacts.rb`
- Modify: `app/models/contact.rb`
- Test: `test/models/contact_test.rb` (create or extend)

**Interfaces:**
- Produces: `Contact.resolve_email(email, name: nil) -> Contact` (creates if missing, tags `sources` with `"meet"`, sets `display_name` if blank).

- [ ] **Step 1: Migration**

```ruby
class AddDisplayNameToContacts < ActiveRecord::Migration[6.1]
  def change
    add_column :contacts, :display_name, :string
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing test**

```ruby
require 'test_helper'

class ContactResolveEmailTest < ActiveSupport::TestCase
  test 'creates a contact for an unknown email and tags meet source' do
    c = Contact.resolve_email('New.Person@sanctuary.computer', name: 'New Person')
    assert_equal 'new.person@sanctuary.computer', c.email
    assert_equal 'New Person', c.display_name
    assert_includes c.sources, 'meet'
  end

  test 'finds an existing contact case-insensitively and adds the meet source' do
    existing = Contact.create!(email: 'dup@gmail.com', sources: ['xxix:newsletter'])
    c = Contact.resolve_email('DUP@gmail.com', name: 'Dup')
    assert_equal existing.id, c.id
    assert_includes c.sources, 'meet'
    assert_includes c.sources, 'xxix:newsletter'
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/models/contact_test.rb -n /ResolveEmail/`
Expected: FAIL (`resolve_email` undefined)

- [ ] **Step 4: Implement**

In `app/models/contact.rb`:

```ruby
def self.resolve_email(email, name: nil)
  normalized = email.to_s.downcase.strip
  contact = create_or_find_by!(email: normalized)
  contact.sources = (contact.sources + ['meet']).uniq
  contact.display_name = name if contact.display_name.blank? && name.present?
  contact.save! if contact.changed?
  contact
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/models/contact_test.rb -n /ResolveEmail/`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/contact.rb test/models/contact_test.rb
git commit -m "feat(etl): contacts gain display_name and resolve_email spine"
```

---

## Task 3: `documents` table + model

**Files:**
- Create: `db/migrate/<ts>_create_documents.rb`, `app/models/document.rb`
- Test: `test/models/document_test.rb`

**Interfaces:**
- Produces: `Document` with enums `source`, `excluded`, `excluded_reason`; scope `Document.corpus_eligible`; `Document#corpus_eligible?`.

- [ ] **Step 1: Migration**

```ruby
class CreateDocuments < ActiveRecord::Migration[6.1]
  def change
    create_table :documents do |t|
      t.integer :source, null: false, default: 0
      t.string :external_id, null: false
      t.references :source_record, polymorphic: true, null: true
      t.string :title
      t.string :url
      t.datetime :occurred_at
      t.string :content_hash
      t.integer :excluded, null: false, default: 0
      t.integer :excluded_reason, null: false, default: 0
      t.string :excluded_by
      t.jsonb :raw_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :documents, [:source, :external_id], unique: true
    add_index :documents, :occurred_at
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing test**

```ruby
require 'test_helper'

class DocumentTest < ActiveSupport::TestCase
  test 'corpus_eligible scope includes not_excluded and manually_included only' do
    a = Document.create!(source: :meet, external_id: 'a', excluded: :not_excluded)
    b = Document.create!(source: :meet, external_id: 'b', excluded: :manually_included)
    Document.create!(source: :meet, external_id: 'c', excluded: :auto_excluded)
    Document.create!(source: :meet, external_id: 'd', excluded: :manually_excluded)
    assert_equal [a.id, b.id].sort, Document.corpus_eligible.pluck(:id).sort
  end

  test 'source+external_id is unique' do
    Document.create!(source: :meet, external_id: 'x')
    assert_raises(ActiveRecord::RecordNotUnique) { Document.create!(source: :meet, external_id: 'x') }
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/models/document_test.rb`
Expected: FAIL (`Document` undefined)

- [ ] **Step 4: Implement model**

```ruby
class Document < ApplicationRecord
  belongs_to :source_record, polymorphic: true, optional: true
  has_many :chunks, dependent: :destroy
  has_many :document_contacts, dependent: :destroy
  has_many :contacts, through: :document_contacts

  enum source: { meet: 0 }
  enum excluded: { not_excluded: 0, auto_excluded: 1, manually_excluded: 2, manually_included: 3 }
  enum excluded_reason: {
    none: 0, one_on_one: 1, performance_review: 2, compensation: 3,
    hr: 4, offboarding: 5, pip: 6, title_keyword: 7, manual: 8
  }, _prefix: :reason

  scope :corpus_eligible, -> { where(excluded: [excludeds[:not_excluded], excludeds[:manually_included]]) }

  def corpus_eligible?
    not_excluded? || manually_included?
  end

  def human_locked?
    manually_excluded? || manually_included?
  end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/models/document_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/document.rb test/models/document_test.rb
git commit -m "feat(etl): documents table with exclusion enums and corpus scope"
```

---

## Task 4: `chunks` table + model

**Files:**
- Create: `db/migrate/<ts>_create_chunks.rb`, `app/models/chunk.rb`
- Test: `test/models/chunk_test.rb`

**Interfaces:**
- Consumes: `Document`.
- Produces: `Chunk` belongs_to `:document`, has a `tsvector` column `content_tsv` (GIN), `start_offset`/`end_offset`, `speaker_name`, `speaker_contact_id`, denormalized `source`/`occurred_at`. Scope `Chunk.keyword_search(query)`.

- [ ] **Step 1: Migration**

```ruby
class CreateChunks < ActiveRecord::Migration[6.1]
  def change
    create_table :chunks do |t|
      t.references :document, null: false, foreign_key: true
      t.integer :position, null: false
      t.text :content, null: false
      t.integer :start_offset
      t.integer :end_offset
      t.string :speaker_name
      t.references :speaker_contact, null: true, foreign_key: { to_table: :contacts }
      t.integer :source, null: false, default: 0
      t.datetime :occurred_at
      t.timestamps
    end
    execute "ALTER TABLE chunks ADD COLUMN content_tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED"
    execute "CREATE INDEX index_chunks_on_content_tsv ON chunks USING gin (content_tsv)"
    add_index :chunks, [:document_id, :position], unique: true
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing test**

```ruby
require 'test_helper'

class ChunkTest < ActiveSupport::TestCase
  setup { @doc = Document.create!(source: :meet, external_id: 'd1') }

  test 'keyword_search matches on generated tsvector' do
    hit  = Chunk.create!(document: @doc, position: 0, content: 'We decided to ship the gateway redesign', source: :meet)
    Chunk.create!(document: @doc, position: 1, content: 'Lunch plans for friday', source: :meet)
    assert_includes Chunk.keyword_search('gateway').to_a, hit
    assert_equal 1, Chunk.keyword_search('gateway').count
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/models/chunk_test.rb`
Expected: FAIL

- [ ] **Step 4: Implement**

```ruby
class Chunk < ApplicationRecord
  belongs_to :document
  belongs_to :speaker_contact, class_name: 'Contact', optional: true
  has_many :mentions, dependent: :destroy
  has_one :embedding, as: :owner, dependent: :destroy

  enum source: { meet: 0 }

  scope :keyword_search, ->(query) {
    where('content_tsv @@ plainto_tsquery(:q)', q: query)
      .order(Arel.sql("ts_rank(content_tsv, plainto_tsquery(#{connection.quote(query)})) DESC"))
  }
  scope :corpus_eligible, -> { joins(:document).merge(Document.corpus_eligible) }
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/models/chunk_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/chunk.rb test/models/chunk_test.rb
git commit -m "feat(etl): chunks table with generated tsvector keyword search"
```

---

## Task 5: `embeddings` side-table + model (neighbor)

**Files:**
- Create: `db/migrate/<ts>_create_embeddings.rb`, `app/models/embedding.rb`
- Test: `test/models/embedding_test.rb`

**Interfaces:**
- Consumes: `Chunk`.
- Produces: `Embedding` (`owner` polymorphic, `model`, `embedding vector(1024)`), `has_neighbors :embedding`; unique `(owner_type, owner_id, model)`.

- [ ] **Step 1: Migration**

```ruby
class CreateEmbeddings < ActiveRecord::Migration[6.1]
  def change
    create_table :embeddings do |t|
      t.references :owner, polymorphic: true, null: false
      t.string :model, null: false
      t.column :embedding, :vector, limit: 1024
      t.timestamps
    end
    add_index :embeddings, [:owner_type, :owner_id, :model], unique: true, name: 'index_embeddings_on_owner_and_model'
    add_index :embeddings, :embedding, using: :hnsw, opclass: :vector_cosine_ops
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing test**

```ruby
require 'test_helper'

class EmbeddingTest < ActiveSupport::TestCase
  setup do
    @doc = Document.create!(source: :meet, external_id: 'd1')
    @chunk = Chunk.create!(document: @doc, position: 0, content: 'hello', source: :meet)
  end

  test 'stores a vector and finds nearest neighbors by cosine' do
    near = Embedding.create!(owner: @chunk, model: 'voyage-3', embedding: Array.new(1024) { 0.0 }.tap { |v| v[0] = 1.0 })
    other = Chunk.create!(document: @doc, position: 1, content: 'bye', source: :meet)
    Embedding.create!(owner: other, model: 'voyage-3', embedding: Array.new(1024) { 0.0 }.tap { |v| v[1] = 1.0 })

    query = Array.new(1024) { 0.0 }.tap { |v| v[0] = 1.0 }
    result = Embedding.where(model: 'voyage-3').nearest_neighbors(:embedding, query, distance: 'cosine').first
    assert_equal near.id, result.id
  end

  test 'one embedding per owner per model' do
    Embedding.create!(owner: @chunk, model: 'voyage-3', embedding: Array.new(1024, 0.0))
    assert_raises(ActiveRecord::RecordNotUnique) do
      Embedding.create!(owner: @chunk, model: 'voyage-3', embedding: Array.new(1024, 0.0))
    end
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/models/embedding_test.rb`
Expected: FAIL

- [ ] **Step 4: Implement**

```ruby
class Embedding < ApplicationRecord
  belongs_to :owner, polymorphic: true
  has_neighbors :embedding
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/models/embedding_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/embedding.rb test/models/embedding_test.rb
git commit -m "feat(etl): polymorphic embeddings side-table with pgvector HNSW"
```

---

## Task 6: `mentions` table + model

**Files:**
- Create: `db/migrate/<ts>_create_mentions.rb`, `app/models/mention.rb`
- Test: `test/models/mention_test.rb`

**Interfaces:**
- Consumes: `Chunk`, `Contact`.
- Produces: `Mention` (`chunk`, `raw_text`, `contact` nullable, `confidence` float, `status` enum). Scope `Mention.unresolved`.

- [ ] **Step 1: Migration**

```ruby
class CreateMentions < ActiveRecord::Migration[6.1]
  def change
    create_table :mentions do |t|
      t.references :chunk, null: false, foreign_key: true
      t.string :raw_text, null: false
      t.references :contact, null: true, foreign_key: true
      t.float :confidence
      t.integer :status, null: false, default: 0
      t.timestamps
    end
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing test**

```ruby
require 'test_helper'

class MentionTest < ActiveSupport::TestCase
  setup do
    @doc = Document.create!(source: :meet, external_id: 'd1')
    @chunk = Chunk.create!(document: @doc, position: 0, content: 'x', source: :meet)
  end

  test 'unresolved scope returns mentions awaiting a contact' do
    u = Mention.create!(chunk: @chunk, raw_text: 'Drew', status: :unresolved)
    Mention.create!(chunk: @chunk, raw_text: 'Hugh', status: :resolved, contact: Contact.create!(email: 'h@x.co'))
    assert_equal [u.id], Mention.unresolved.pluck(:id)
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/models/mention_test.rb`
Expected: FAIL

- [ ] **Step 4: Implement**

```ruby
class Mention < ApplicationRecord
  belongs_to :chunk
  belongs_to :contact, optional: true

  enum status: { unresolved: 0, resolved: 1, ambiguous: 2 }
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/models/mention_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/mention.rb test/models/mention_test.rb
git commit -m "feat(etl): mentions table (raw->contact resolution queue)"
```

---

## Task 7: `document_contacts` facet + model

**Files:**
- Create: `db/migrate/<ts>_create_document_contacts.rb`, `app/models/document_contact.rb`
- Test: `test/models/document_contact_test.rb`

**Interfaces:**
- Consumes: `Document`, `Contact`.
- Produces: `DocumentContact` (`document`, `contact` nullable, `email`, `name`, `role`). Unique `(document_id, contact_id, role)`.

- [ ] **Step 1: Migration**

```ruby
class CreateDocumentContacts < ActiveRecord::Migration[6.1]
  def change
    create_table :document_contacts do |t|
      t.references :document, null: false, foreign_key: true
      t.references :contact, null: true, foreign_key: true
      t.string :email
      t.string :name
      t.string :role
      t.timestamps
    end
    add_index :document_contacts, [:document_id, :contact_id, :role], unique: true, name: 'index_document_contacts_unique'
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing test**

```ruby
require 'test_helper'

class DocumentContactTest < ActiveSupport::TestCase
  test 'links a document to a contact with a role' do
    doc = Document.create!(source: :meet, external_id: 'd1')
    contact = Contact.create!(email: 'a@b.co')
    dc = DocumentContact.create!(document: doc, contact: contact, email: 'a@b.co', role: 'participant')
    assert_includes doc.reload.contacts, contact
    assert_equal 'participant', dc.role
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/models/document_contact_test.rb`
Expected: FAIL

- [ ] **Step 4: Implement**

```ruby
class DocumentContact < ApplicationRecord
  belongs_to :document
  belongs_to :contact, optional: true
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/models/document_contact_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/document_contact.rb test/models/document_contact_test.rb
git commit -m "feat(etl): document_contacts facet"
```

---

## Task 8: `source_syncs` watermark + model

**Files:**
- Create: `db/migrate/<ts>_create_source_syncs.rb`, `app/models/source_sync.rb`
- Test: `test/models/source_sync_test.rb`

**Interfaces:**
- Produces: `SourceSync.for(source)` returns the singleton row for a source (created if absent); `#cursor` jsonb, `#stats` jsonb, `#advance!(cursor:, stats:)`.

- [ ] **Step 1: Migration**

```ruby
class CreateSourceSyncs < ActiveRecord::Migration[6.1]
  def change
    create_table :source_syncs do |t|
      t.string :source, null: false
      t.jsonb :cursor, null: false, default: {}
      t.datetime :last_run_at
      t.string :status
      t.jsonb :stats, null: false, default: {}
      t.references :system_task, null: true, foreign_key: true
      t.timestamps
    end
    add_index :source_syncs, :source, unique: true
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing test**

```ruby
require 'test_helper'

class SourceSyncTest < ActiveSupport::TestCase
  test 'for returns a singleton per source and advance! stores cursor' do
    s1 = SourceSync.for('meet')
    s2 = SourceSync.for('meet')
    assert_equal s1.id, s2.id
    s1.advance!(cursor: { 'last_end_time' => '2026-06-01T00:00:00Z' }, stats: { 'documents' => 3 })
    assert_equal '2026-06-01T00:00:00Z', SourceSync.for('meet').cursor['last_end_time']
    assert_equal 3, SourceSync.for('meet').stats['documents']
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/models/source_sync_test.rb`
Expected: FAIL

- [ ] **Step 4: Implement**

```ruby
class SourceSync < ApplicationRecord
  belongs_to :system_task, optional: true

  def self.for(source)
    create_or_find_by!(source: source.to_s)
  end

  def advance!(cursor: nil, stats: nil, status: 'success')
    self.cursor = cursor if cursor
    self.stats = stats if stats
    self.status = status
    self.last_run_at = Time.current
    save!
  end
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/models/source_sync_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/source_sync.rb test/models/source_sync_test.rb
git commit -m "feat(etl): source_syncs watermark per source"
```

---

## Task 9: Meet connector tables + models

**Files:**
- Create: `db/migrate/<ts>_create_meet_tables.rb`, `app/models/meeting.rb`, `app/models/meeting_participant.rb`, `app/models/meeting_transcript_segment.rb`
- Test: `test/models/meeting_test.rb`

**Interfaces:**
- Consumes: `Document`, `Contact`.
- Produces: `Meeting` (`has_one :document, as: :source_record`), `meet_source` enum, unique `meet_conference_record_id` / `drive_transcript_doc_id`; `MeetingParticipant`; `MeetingTranscriptSegment` ordered by `position`.

- [ ] **Step 1: Migration**

```ruby
class CreateMeetTables < ActiveRecord::Migration[6.1]
  def change
    create_table :meetings do |t|
      t.string :meet_conference_record_id
      t.string :drive_transcript_doc_id
      t.integer :meet_source, null: false, default: 0
      t.string :title
      t.string :organizer_email
      t.datetime :started_at
      t.datetime :ended_at
      t.integer :participant_count
      t.jsonb :raw_metadata, null: false, default: {}
      t.timestamps
    end
    add_index :meetings, :meet_conference_record_id, unique: true, where: 'meet_conference_record_id IS NOT NULL'
    add_index :meetings, :drive_transcript_doc_id, unique: true, where: 'drive_transcript_doc_id IS NOT NULL'

    create_table :meeting_participants do |t|
      t.references :meeting, null: false, foreign_key: true
      t.string :name
      t.string :email
      t.references :contact, null: true, foreign_key: true
      t.datetime :join_at
      t.datetime :leave_at
      t.timestamps
    end

    create_table :meeting_transcript_segments do |t|
      t.references :meeting, null: false, foreign_key: true
      t.string :speaker_name
      t.string :speaker_email
      t.references :speaker_contact, null: true, foreign_key: { to_table: :contacts }
      t.datetime :started_at
      t.datetime :ended_at
      t.integer :position, null: false
      t.text :text, null: false
      t.timestamps
    end
    add_index :meeting_transcript_segments, [:meeting_id, :position], unique: true
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: Write the failing test**

```ruby
require 'test_helper'

class MeetingTest < ActiveSupport::TestCase
  test 'meeting owns a document as source_record and orders segments' do
    meeting = Meeting.create!(meet_conference_record_id: 'conferenceRecords/1', title: 'Standup', meet_source: :meet_api)
    Document.create!(source: :meet, external_id: 'conferenceRecords/1', source_record: meeting)
    meeting.segments.create!(position: 1, text: 'second', speaker_name: 'B')
    meeting.segments.create!(position: 0, text: 'first', speaker_name: 'A')
    assert_equal %w[first second], meeting.segments.order(:position).pluck(:text)
    assert_equal meeting, meeting.document.source_record
  end

  test 'conference record id is unique when present' do
    Meeting.create!(meet_conference_record_id: 'conferenceRecords/9', meet_source: :meet_api)
    assert_raises(ActiveRecord::RecordNotUnique) do
      Meeting.create!(meet_conference_record_id: 'conferenceRecords/9', meet_source: :meet_api)
    end
  end
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `bin/rails test test/models/meeting_test.rb`
Expected: FAIL

- [ ] **Step 4: Implement models**

`app/models/meeting.rb`:

```ruby
class Meeting < ApplicationRecord
  has_one :document, as: :source_record
  has_many :participants, class_name: 'MeetingParticipant', dependent: :destroy
  has_many :segments, class_name: 'MeetingTranscriptSegment', dependent: :destroy

  enum meet_source: { meet_api: 0, drive: 1 }
end
```

`app/models/meeting_participant.rb`:

```ruby
class MeetingParticipant < ApplicationRecord
  belongs_to :meeting
  belongs_to :contact, optional: true
end
```

`app/models/meeting_transcript_segment.rb`:

```ruby
class MeetingTranscriptSegment < ApplicationRecord
  belongs_to :meeting
  belongs_to :speaker_contact, class_name: 'Contact', optional: true
end
```

- [ ] **Step 5: Run to verify it passes**

Run: `bin/rails test test/models/meeting_test.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/meeting.rb app/models/meeting_participant.rb app/models/meeting_transcript_segment.rb test/models/meeting_test.rb
git commit -m "feat(etl): meet connector tables (meetings/participants/segments)"
```

---

## Task 10: Voyage embedder

**Files:**
- Create: `lib/stacks/etl/embedder.rb`
- Test: `test/lib/stacks/etl/embedder_test.rb`

**Interfaces:**
- Produces: `Stacks::Etl::Embedder.embed(texts, input_type: 'document') -> { vectors: [[Float]], total_tokens: Integer }`. `MODEL = 'voyage-3'`, `DIMENSIONS = 1024`.

- [ ] **Step 1: Write the failing test**

```ruby
require 'test_helper'

class Stacks::Etl::EmbedderTest < ActiveSupport::TestCase
  test 'embed posts to voyage and returns vectors ordered by index' do
    fake = mock('resp')
    fake.stubs(:success?).returns(true)
    fake.stubs(:parsed_response).returns({
      'data' => [
        { 'index' => 1, 'embedding' => [0.2] * 1024 },
        { 'index' => 0, 'embedding' => [0.1] * 1024 }
      ],
      'usage' => { 'total_tokens' => 42 }
    })
    Stacks::Utils.stubs(:config).returns(voyage: { api_key: 'k' })
    HTTParty.expects(:post).with do |url, opts|
      url == 'https://api.voyageai.com/v1/embeddings' &&
        JSON.parse(opts[:body])['model'] == 'voyage-3' &&
        JSON.parse(opts[:body])['input'] == %w[a b]
    end.returns(fake)

    out = Stacks::Etl::Embedder.embed(%w[a b])
    assert_equal [[0.1] * 1024, [0.2] * 1024], out[:vectors]
    assert_equal 42, out[:total_tokens]
  end

  test 'raises on a non-success response' do
    fake = mock('resp'); fake.stubs(:success?).returns(false); fake.stubs(:code).returns(429); fake.stubs(:body).returns('rate limited')
    Stacks::Utils.stubs(:config).returns(voyage: { api_key: 'k' })
    HTTParty.stubs(:post).returns(fake)
    assert_raises(Stacks::Etl::Embedder::Error) { Stacks::Etl::Embedder.embed(['x']) }
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/embedder_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

```ruby
module Stacks
  module Etl
    class Embedder
      Error = Class.new(StandardError)
      ENDPOINT = 'https://api.voyageai.com/v1/embeddings'.freeze
      MODEL = 'voyage-3'.freeze
      DIMENSIONS = 1024

      def self.embed(texts, input_type: 'document', model: MODEL)
        body = { input: Array(texts), model: model, input_type: input_type, truncation: true }
        response = HTTParty.post(
          ENDPOINT,
          headers: {
            'Authorization' => "Bearer #{Stacks::Utils.config[:voyage][:api_key]}",
            'Content-Type' => 'application/json'
          },
          body: body.to_json
        )
        raise Error, "Voyage #{response.code}: #{response.body}" unless response.success?

        parsed = response.parsed_response
        vectors = parsed['data'].sort_by { |d| d['index'] }.map { |d| d['embedding'] }
        { vectors: vectors, total_tokens: parsed.dig('usage', 'total_tokens') }
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/embedder_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/embedder.rb test/lib/stacks/etl/embedder_test.rb
git commit -m "feat(etl): Voyage embedder"
```

---

## Task 11: Chunker

**Files:**
- Create: `lib/stacks/etl/chunker.rb`
- Test: `test/lib/stacks/etl/chunker_test.rb`

**Interfaces:**
- Produces: `Stacks::Etl::Chunker.call(segments:) -> [{ content:, start_offset:, end_offset:, speaker_name:, speaker_email:, occurred_at: }]`. Each input segment is `{ speaker_name:, speaker_email:, text:, started_at: }`. Groups consecutive same-speaker turns; splits any chunk whose word count exceeds `MAX_WORDS` (≈512 tokens), with `OVERLAP_WORDS` overlap; offsets are word indices into the meeting's flattened text.

- [ ] **Step 1: Write the failing test**

```ruby
require 'test_helper'

class Stacks::Etl::ChunkerTest < ActiveSupport::TestCase
  test 'one chunk per speaker turn, carrying speaker + timestamp' do
    segs = [
      { speaker_name: 'A', speaker_email: 'a@x.co', text: 'hello there', started_at: Time.utc(2026, 1, 1, 9) },
      { speaker_name: 'B', speaker_email: 'b@x.co', text: 'general kenobi', started_at: Time.utc(2026, 1, 1, 9, 1) }
    ]
    chunks = Stacks::Etl::Chunker.call(segments: segs)
    assert_equal 2, chunks.size
    assert_equal 'hello there', chunks[0][:content]
    assert_equal 'A', chunks[0][:speaker_name]
    assert_equal 'b@x.co', chunks[1][:speaker_email]
  end

  test 'splits an over-long turn into overlapping chunks' do
    long = (1..600).map { |i| "w#{i}" }.join(' ')
    chunks = Stacks::Etl::Chunker.call(segments: [{ speaker_name: 'A', speaker_email: 'a@x.co', text: long, started_at: Time.now }])
    assert_operator chunks.size, :>=, 2
    assert chunks.all? { |c| c[:content].split.size <= Stacks::Etl::Chunker::MAX_WORDS }
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/chunker_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

```ruby
module Stacks
  module Etl
    class Chunker
      MAX_WORDS = 380      # ~512 tokens
      OVERLAP_WORDS = 40

      def self.call(segments:)
        chunks = []
        segments.each do |seg|
          words = seg[:text].to_s.split
          next if words.empty?
          slices(words).each do |slice|
            chunks << {
              content: slice.join(' '),
              start_offset: nil,
              end_offset: nil,
              speaker_name: seg[:speaker_name],
              speaker_email: seg[:speaker_email],
              occurred_at: seg[:started_at]
            }
          end
        end
        chunks.each_with_index { |c, i| c[:start_offset] = i }
        chunks
      end

      def self.slices(words)
        return [words] if words.size <= MAX_WORDS
        out = []
        i = 0
        while i < words.size
          out << words[i, MAX_WORDS]
          i += MAX_WORDS - OVERLAP_WORDS
        end
        out
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/chunker_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/chunker.rb test/lib/stacks/etl/chunker_test.rb
git commit -m "feat(etl): speaker-aware chunker with overlap"
```

---

## Task 12: Mention resolver

**Files:**
- Create: `lib/stacks/etl/mention_resolver.rb`
- Test: `test/lib/stacks/etl/mention_resolver_test.rb`

**Interfaces:**
- Consumes: `Contact`.
- Produces:
  - `Stacks::Etl::MentionResolver.resolve_email(email, name: nil) -> Contact` (delegates to `Contact.resolve_email`).
  - `Stacks::Etl::MentionResolver.resolve_display_name(name, participants:) -> { contact:, confidence:, status: }` where `participants` is `[{ name:, contact: }]`. Exact (case-insensitive) match → confidence 1.0, status `resolved`; unique first-name/substring match → 0.6, `resolved`; multiple candidates → `ambiguous`; none → `unresolved`.

- [ ] **Step 1: Write the failing test**

```ruby
require 'test_helper'

class Stacks::Etl::MentionResolverTest < ActiveSupport::TestCase
  setup do
    @drew = Contact.create!(email: 'drew@sanctuary.computer', display_name: 'Drew Smith')
    @hugh = Contact.create!(email: 'hugh@sanctuary.computer', display_name: 'Hugh Francis')
    @participants = [{ name: 'Drew Smith', contact: @drew }, { name: 'Hugh Francis', contact: @hugh }]
  end

  test 'resolve_email makes/find a contact' do
    c = Stacks::Etl::MentionResolver.resolve_email('guest@gmail.com', name: 'Guest')
    assert_equal 'guest@gmail.com', c.email
  end

  test 'exact display-name match resolves at full confidence' do
    r = Stacks::Etl::MentionResolver.resolve_display_name('drew smith', participants: @participants)
    assert_equal @drew.id, r[:contact].id
    assert_equal 'resolved', r[:status]
    assert_equal 1.0, r[:confidence]
  end

  test 'unique first-name match resolves at partial confidence' do
    r = Stacks::Etl::MentionResolver.resolve_display_name('Drew', participants: @participants)
    assert_equal @drew.id, r[:contact].id
    assert_equal 'resolved', r[:status]
    assert_in_delta 0.6, r[:confidence], 0.001
  end

  test 'no match is unresolved' do
    r = Stacks::Etl::MentionResolver.resolve_display_name('Zoltan', participants: @participants)
    assert_nil r[:contact]
    assert_equal 'unresolved', r[:status]
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/mention_resolver_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

```ruby
module Stacks
  module Etl
    class MentionResolver
      def self.resolve_email(email, name: nil)
        Contact.resolve_email(email, name: name)
      end

      def self.resolve_display_name(name, participants:)
        needle = name.to_s.downcase.strip
        exact = participants.select { |p| p[:name].to_s.downcase.strip == needle }
        return resolved(exact.first[:contact], 1.0) if exact.size == 1

        partial = participants.select do |p|
          full = p[:name].to_s.downcase
          full.split.include?(needle) || full.include?(needle)
        end
        return resolved(partial.first[:contact], 0.6) if partial.size == 1
        return { contact: nil, confidence: nil, status: 'ambiguous' } if partial.size > 1

        { contact: nil, confidence: nil, status: 'unresolved' }
      end

      def self.resolved(contact, confidence)
        { contact: contact, confidence: confidence, status: 'resolved' }
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/mention_resolver_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/mention_resolver.rb test/lib/stacks/etl/mention_resolver_test.rb
git commit -m "feat(etl): mention resolver (email + display-name)"
```

---

## Task 13: ETL connector base

**Files:**
- Create: `lib/stacks/etl/connector.rb`
- Test: `test/lib/stacks/etl/connector_test.rb`

**Interfaces:**
- Consumes: `Document`, `Chunk`, `Embedding`, `DocumentContact`, `Mention`, `SourceSync`, `Stacks::Etl::Chunker`, `Stacks::Etl::Embedder`, `Stacks::Etl::MentionResolver`.
- A normalized document is a Hash: `{ external_id:, title:, url:, occurred_at:, content_hash:, contacts: [{email:, name:, role:}], segments: [{speaker_name:, speaker_email:, text:, started_at:, ended_at:}], raw_metadata:, build_source_record: ->(document) { meeting } }`.
- Subclasses implement: `#source` (Symbol), `#extract(since:)` (yields/returns normalized docs), `#exclusion_for(normalized)` → `[excluded(Symbol), excluded_reason(Symbol)]` (default `[:not_excluded, :none]`).
- Produces: `#run(since: nil) -> SourceSync` — full pipeline, advancing the watermark; returns the `SourceSync`.

- [ ] **Step 1: Write the failing test** (uses an in-test fake subclass)

```ruby
require 'test_helper'

class Stacks::Etl::ConnectorTest < ActiveSupport::TestCase
  class FakeConnector < Stacks::Etl::Connector
    def initialize(docs, exclusion: [:not_excluded, :none])
      @docs = docs; @exclusion = exclusion
    end
    def source = :meet
    def extract(since:) = @docs
    def exclusion_for(_n) = @exclusion
  end

  def normalized(external_id:, hash:, excluded: false)
    {
      external_id: external_id, title: 'T', url: 'http://x', occurred_at: Time.utc(2026, 1, 1),
      content_hash: hash,
      contacts: [{ email: 'a@x.co', name: 'A', role: 'participant' }],
      segments: [{ speaker_name: 'A', speaker_email: 'a@x.co', text: 'we decided to ship', started_at: Time.utc(2026, 1, 1) }],
      raw_metadata: {}, build_source_record: ->(_doc) { nil }
    }
  end

  setup do
    Stacks::Etl::Embedder.stubs(:embed).returns(vectors: [[0.5] * 1024], total_tokens: 1)
  end

  test 'ingests a corpus-eligible document: chunks, embeds, links contacts' do
    FakeConnector.new([normalized(external_id: 'm1', hash: 'h1')]).run
    doc = Document.find_by!(source: :meet, external_id: 'm1')
    assert_equal 1, doc.chunks.count
    assert_equal 1, Embedding.where(owner: doc.chunks.first).count
    assert_equal ['a@x.co'], doc.document_contacts.pluck(:email)
    assert doc.not_excluded?
  end

  test 'unchanged content_hash skips re-chunking' do
    conn = FakeConnector.new([normalized(external_id: 'm1', hash: 'h1')])
    conn.run
    Stacks::Etl::Chunker.expects(:call).never
    FakeConnector.new([normalized(external_id: 'm1', hash: 'h1')]).run
  end

  test 'excluded document gets no chunks or embeddings' do
    FakeConnector.new([normalized(external_id: 'm2', hash: 'h2')], exclusion: [:auto_excluded, :one_on_one]).run
    doc = Document.find_by!(external_id: 'm2')
    assert doc.auto_excluded?
    assert_equal 0, doc.chunks.count
  end

  test 'human-locked exclusion is not overwritten by the classifier' do
    FakeConnector.new([normalized(external_id: 'm3', hash: 'h3')]).run
    Document.find_by!(external_id: 'm3').update!(excluded: :manually_excluded, excluded_reason: :manual)
    FakeConnector.new([normalized(external_id: 'm3', hash: 'h3b')], exclusion: [:not_excluded, :none]).run
    assert Document.find_by!(external_id: 'm3').manually_excluded?
  end

  test 'advances the watermark' do
    sync = FakeConnector.new([normalized(external_id: 'm1', hash: 'h1')]).run
    assert_equal 'success', sync.status
    assert_equal 1, sync.stats['documents']
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/connector_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

```ruby
module Stacks
  module Etl
    class Connector
      def run(since: nil)
        sync = SourceSync.for(source)
        count = 0
        Array(extract(since: since || sync.cursor['since'])).each do |normalized|
          ingest(normalized)
          count += 1
        end
        sync.advance!(cursor: { 'since' => Time.current.iso8601 }, stats: { 'documents' => count })
        sync
      end

      def exclusion_for(_normalized) = [:not_excluded, :none]

      private

      def ingest(normalized)
        ActiveRecord::Base.transaction do
          doc = Document.find_or_initialize_by(source: source, external_id: normalized[:external_id])
          changed = doc.new_record? || doc.content_hash != normalized[:content_hash]

          doc.assign_attributes(
            title: normalized[:title], url: normalized[:url],
            occurred_at: normalized[:occurred_at], content_hash: normalized[:content_hash],
            raw_metadata: normalized[:raw_metadata] || {}
          )
          doc.source_record = normalized[:build_source_record]&.call(doc)
          apply_exclusion(doc, normalized) unless doc.human_locked?
          doc.save!

          sync_document_contacts(doc, normalized[:contacts])

          if changed && doc.corpus_eligible?
            rebuild_chunks(doc, normalized[:segments])
          elsif !doc.corpus_eligible?
            doc.chunks.destroy_all
          end
        end
      end

      def apply_exclusion(doc, normalized)
        excluded, reason = exclusion_for(normalized)
        doc.excluded = excluded
        doc.excluded_reason = reason
      end

      def sync_document_contacts(doc, contacts)
        doc.document_contacts.destroy_all
        Array(contacts).each do |c|
          contact = c[:email].present? ? MentionResolver.resolve_email(c[:email], name: c[:name]) : nil
          doc.document_contacts.create!(contact: contact, email: c[:email], name: c[:name], role: c[:role])
        end
      end

      def rebuild_chunks(doc, segments)
        doc.chunks.destroy_all
        chunk_rows = Chunker.call(segments: Array(segments))
        return if chunk_rows.empty?

        participants = doc.document_contacts.map { |dc| { name: dc.name, contact: dc.contact } }
        embeddings = Embedder.embed(chunk_rows.map { |c| c[:content] })[:vectors]

        chunk_rows.each_with_index do |row, i|
          speaker = row[:speaker_email].present? ? MentionResolver.resolve_email(row[:speaker_email], name: row[:speaker_name]) : nil
          chunk = doc.chunks.create!(
            position: i, content: row[:content],
            start_offset: row[:start_offset], end_offset: row[:end_offset],
            speaker_name: row[:speaker_name], speaker_contact: speaker,
            source: source, occurred_at: row[:occurred_at]
          )
          resolve_mention(chunk, row, participants, speaker)
          Embedding.create!(owner: chunk, model: Embedder::MODEL, embedding: embeddings[i])
        end
      end

      def resolve_mention(chunk, row, participants, speaker)
        return if speaker.present? || row[:speaker_name].blank?
        r = MentionResolver.resolve_display_name(row[:speaker_name], participants: participants)
        chunk.update!(speaker_contact: r[:contact]) if r[:contact]
        chunk.mentions.create!(raw_text: row[:speaker_name], contact: r[:contact], confidence: r[:confidence], status: r[:status])
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/connector_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/connector.rb test/lib/stacks/etl/connector_test.rb
git commit -m "feat(etl): connector base pipeline (upsert/chunk/embed/resolve/exclude)"
```

---

## Task 14: Meet auth

**Files:**
- Create: `lib/stacks/etl/meet/auth.rb`
- Test: `test/lib/stacks/etl/meet/auth_test.rb`

**Interfaces:**
- Produces: `Stacks::Etl::Meet::Auth.meet_service(sub:) -> Google::Apis::MeetV2::MeetService`, `.drive_service(sub:) -> Google::Apis::DriveV3::DriveService`. Both build `ServiceAccountCredentials` from `Stacks::Utils.config[:google_oauth2][:service_account]`, set `authorization.sub = sub`, fetch the token. Mirrors `lib/stacks/calendar.rb`.

- [ ] **Step 1: Write the failing test**

```ruby
require 'test_helper'

class Stacks::Etl::Meet::AuthTest < ActiveSupport::TestCase
  test 'meet_service impersonates the given sub' do
    creds = mock('creds')
    creds.expects(:sub=).with('organizer@sanctuary.computer')
    creds.expects(:fetch_access_token!)
    Stacks::Utils.stubs(:config).returns(google_oauth2: { service_account: '{}' })
    Google::Auth::ServiceAccountCredentials.stubs(:make_creds).returns(creds)

    service = Stacks::Etl::Meet::Auth.meet_service(sub: 'organizer@sanctuary.computer')
    assert_kind_of Google::Apis::MeetV2::MeetService, service
    assert_equal creds, service.authorization
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/meet/auth_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

```ruby
require 'google/apis/meet_v2'
require 'google/apis/drive_v3'
require 'googleauth'

module Stacks
  module Etl
    module Meet
      class Auth
        SCOPES = [
          'https://www.googleapis.com/auth/meetings.space.readonly',
          'https://www.googleapis.com/auth/drive.readonly'
        ].freeze

        def self.meet_service(sub:)
          service = Google::Apis::MeetV2::MeetService.new
          service.authorization = credentials(sub)
          service
        end

        def self.drive_service(sub:)
          service = Google::Apis::DriveV3::DriveService.new
          service.authorization = credentials(sub)
          service
        end

        def self.credentials(sub)
          creds = Google::Auth::ServiceAccountCredentials.make_creds(
            json_key_io: StringIO.new(Stacks::Utils.config[:google_oauth2][:service_account]),
            scope: SCOPES
          )
          creds.sub = sub
          creds.fetch_access_token!
          creds
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/meet/auth_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/meet/auth.rb test/lib/stacks/etl/meet/auth_test.rb
git commit -m "feat(etl): Meet/Drive service-account auth with impersonation"
```

---

## Task 15: Meet exclusion classifier

**Files:**
- Create: `lib/stacks/etl/meet/classifier.rb`
- Test: `test/lib/stacks/etl/meet/classifier_test.rb`

**Interfaces:**
- Produces: `Stacks::Etl::Meet::Classifier.call(title:, participant_count:) -> [Symbol excluded, Symbol reason]`.

- [ ] **Step 1: Write the failing test**

```ruby
require 'test_helper'

class Stacks::Etl::Meet::ClassifierTest < ActiveSupport::TestCase
  C = Stacks::Etl::Meet::Classifier

  test '1:1 by participant count' do
    assert_equal [:auto_excluded, :one_on_one], C.call(title: 'Sync', participant_count: 2)
  end

  test 'title families' do
    assert_equal [:auto_excluded, :one_on_one], C.call(title: 'Drew / Hugh 1:1', participant_count: 5)
    assert_equal [:auto_excluded, :performance_review], C.call(title: 'Q2 Performance Review', participant_count: 5)
    assert_equal [:auto_excluded, :compensation], C.call(title: 'Comp planning', participant_count: 5)
    assert_equal [:auto_excluded, :hr], C.call(title: 'HR catchup', participant_count: 5)
    assert_equal [:auto_excluded, :offboarding], C.call(title: 'Termination discussion', participant_count: 5)
    assert_equal [:auto_excluded, :pip], C.call(title: 'PIP review', participant_count: 5)
  end

  test 'ordinary group meeting is not excluded' do
    assert_equal [:not_excluded, :none], C.call(title: 'Gateway redesign kickoff', participant_count: 6)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/meet/classifier_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

```ruby
module Stacks
  module Etl
    module Meet
      class Classifier
        RULES = [
          [:one_on_one,         /\b1\s*[:\-]?\s*1\b|\bone[\s-]on[\s-]one\b/i],
          [:performance_review, /\bperformance review\b|\breview\b/i],
          [:compensation,       /\bsalary\b|\bcomp(ensation)?\b/i],
          [:hr,                 /\bhr\b/i],
          [:offboarding,        /\boffboarding\b|\btermination\b/i],
          [:pip,                /\bpip\b/i]
        ].freeze

        def self.call(title:, participant_count:)
          return [:auto_excluded, :one_on_one] if participant_count && participant_count <= 2
          RULES.each do |reason, rx|
            return [:auto_excluded, reason] if title.to_s.match?(rx)
          end
          [:not_excluded, :none]
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/meet/classifier_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/meet/classifier.rb test/lib/stacks/etl/meet/classifier_test.rb
git commit -m "feat(etl): Meet exclusion classifier"
```

---

## Task 16: Meet API source (ongoing)

**Files:**
- Create: `lib/stacks/etl/meet/meet_api_source.rb`
- Test: `test/lib/stacks/etl/meet/meet_api_source_test.rb`

**Interfaces:**
- Consumes: `Stacks::Etl::Meet::Auth`.
- Produces: `Stacks::Etl::Meet::MeetApiSource.new(admin_email).each_meeting { |normalized| ... }` — for the admin's accessible conference records, yields normalized documents (per the Connector contract) including `build_source_record` that creates/updates a `Meeting` (+ participants + segments). `content_hash = Digest::SHA256` of concatenated entry text.

- [ ] **Step 1: Write the failing test**

```ruby
require 'test_helper'

class Stacks::Etl::Meet::MeetApiSourceTest < ActiveSupport::TestCase
  test 'normalizes a conference record into a document with segments' do
    cr = OpenStruct.new(name: 'conferenceRecords/1', start_time: '2026-01-01T09:00:00Z', end_time: '2026-01-01T09:30:00Z',
                        space: OpenStruct.new(meeting_code: 'abc'))
    transcript = OpenStruct.new(name: 'conferenceRecords/1/transcripts/1')
    entry = OpenStruct.new(participant: 'p1', text: 'we decided to ship', start_time: '2026-01-01T09:01:00Z', end_time: '2026-01-01T09:01:05Z')
    participant = OpenStruct.new(name: 'p1', signedin_user: OpenStruct.new(display_name: 'Drew'))

    svc = mock('svc')
    svc.stubs(:list_conference_records).returns(OpenStruct.new(conference_records: [cr], next_page_token: nil))
    svc.stubs(:list_conference_record_transcripts).returns(OpenStruct.new(transcripts: [transcript], next_page_token: nil))
    svc.stubs(:list_conference_record_transcript_entries).returns(OpenStruct.new(transcript_entries: [entry], next_page_token: nil))
    svc.stubs(:list_conference_record_participants).returns(OpenStruct.new(participants: [participant], next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:meet_service).returns(svc)

    yielded = []
    Stacks::Etl::Meet::MeetApiSource.new('hugh@sanctuary.computer').each_meeting { |n| yielded << n }

    assert_equal 1, yielded.size
    n = yielded.first
    assert_equal 'conferenceRecords/1', n[:external_id]
    assert_equal 'we decided to ship', n[:segments].first[:text]
    meeting = n[:build_source_record].call(Document.create!(source: :meet, external_id: n[:external_id]))
    assert_equal 'conferenceRecords/1', meeting.meet_conference_record_id
    assert_equal 1, meeting.segments.count
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/meet/meet_api_source_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

```ruby
require 'digest'

module Stacks
  module Etl
    module Meet
      class MeetApiSource
        def initialize(admin_email)
          @admin_email = admin_email
          @service = Auth.meet_service(sub: admin_email)
        end

        def each_meeting
          page = nil
          loop do
            resp = @service.list_conference_records(page_token: page)
            Array(resp.conference_records).each { |cr| yield normalize(cr) }
            page = resp.next_page_token
            break unless page
          end
        end

        private

        def normalize(cr)
          participants = fetch_participants(cr.name)
          segments = fetch_segments(cr.name, participants)
          text = segments.map { |s| s[:text] }.join("\n")
          {
            external_id: cr.name,
            title: cr.space&.meeting_code,
            url: "https://meet.google.com/#{cr.space&.meeting_code}",
            occurred_at: cr.start_time,
            content_hash: Digest::SHA256.hexdigest(text),
            contacts: participants.values.map { |p| { email: p[:email], name: p[:name], role: 'participant' } },
            segments: segments,
            raw_metadata: { 'conference_record' => cr.name },
            build_source_record: ->(doc) { build_meeting(doc, cr, participants, segments) }
          }
        end

        def fetch_participants(cr_name)
          map = {}
          page = nil
          loop do
            resp = @service.list_conference_record_participants(cr_name, page_token: page)
            Array(resp.participants).each do |p|
              map[p.name] = { name: p.signedin_user&.display_name, email: nil }
            end
            page = resp.next_page_token
            break unless page
          end
          map
        end

        def fetch_segments(cr_name, participants)
          segments = []
          tpage = nil
          loop do
            tresp = @service.list_conference_record_transcripts(cr_name, page_token: tpage)
            Array(tresp.transcripts).each do |t|
              epage = nil
              loop do
                eresp = @service.list_conference_record_transcript_entries(t.name, page_size: 100, page_token: epage)
                Array(eresp.transcript_entries).each do |e|
                  speaker = participants[e.participant] || {}
                  segments << { speaker_name: speaker[:name], speaker_email: speaker[:email], text: e.text,
                                started_at: e.start_time, ended_at: e.end_time }
                end
                epage = eresp.next_page_token
                break unless epage
              end
            end
            tpage = tresp.next_page_token
            break unless tpage
          end
          segments
        end

        def build_meeting(doc, cr, participants, segments)
          meeting = Meeting.find_or_initialize_by(meet_conference_record_id: cr.name)
          meeting.update!(meet_source: :meet_api, title: cr.space&.meeting_code, started_at: cr.start_time,
                          ended_at: cr.end_time, participant_count: participants.size,
                          raw_metadata: { 'document_id' => doc.id })
          meeting.participants.destroy_all
          participants.each_value { |p| meeting.participants.create!(name: p[:name], email: p[:email]) }
          meeting.segments.destroy_all
          segments.each_with_index do |s, i|
            meeting.segments.create!(position: i, speaker_name: s[:speaker_name], speaker_email: s[:speaker_email],
                                     started_at: s[:started_at], ended_at: s[:ended_at], text: s[:text])
          end
          meeting
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/meet/meet_api_source_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/meet/meet_api_source.rb test/lib/stacks/etl/meet/meet_api_source_test.rb
git commit -m "feat(etl): Meet REST API source (conference records -> segments)"
```

---

## Task 17: Drive source (backfill)

**Files:**
- Create: `lib/stacks/etl/meet/drive_source.rb`
- Test: `test/lib/stacks/etl/meet/drive_source_test.rb`

**Interfaces:**
- Consumes: `Stacks::Etl::Meet::Auth`.
- Produces: `Stacks::Etl::Meet::DriveSource.new(user_email, since:).each_meeting { |normalized| ... }` — lists the user's Drive Google-Docs named like a Meet transcript created since `since`, exports each as `text/plain`, parses speaker turns (`Name: text` lines) into segments, yields a normalized document whose `build_source_record` creates a `Meeting` keyed by `drive_transcript_doc_id`.

- [ ] **Step 1: Write the failing test**

```ruby
require 'test_helper'

class Stacks::Etl::Meet::DriveSourceTest < ActiveSupport::TestCase
  test 'normalizes a Drive transcript doc into segments' do
    file = OpenStruct.new(id: 'doc1', name: 'Gateway sync - Transcript', created_time: '2026-01-01T09:00:00Z')
    svc = mock('drive')
    svc.stubs(:list_files).returns(OpenStruct.new(files: [file], next_page_token: nil))
    svc.stubs(:export_file).returns("Drew: we should ship\nHugh: agreed, friday")
    Stacks::Etl::Meet::Auth.stubs(:drive_service).returns(svc)

    yielded = []
    Stacks::Etl::Meet::DriveSource.new('hugh@sanctuary.computer', since: Time.utc(2025, 1, 1)).each_meeting { |n| yielded << n }

    n = yielded.first
    assert_equal 'doc1', n[:external_id]
    assert_equal 2, n[:segments].size
    assert_equal 'Drew', n[:segments].first[:speaker_name]
    assert_equal 'we should ship', n[:segments].first[:text]
    meeting = n[:build_source_record].call(Document.create!(source: :meet, external_id: 'doc1'))
    assert_equal 'doc1', meeting.drive_transcript_doc_id
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/meet/drive_source_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

```ruby
require 'digest'

module Stacks
  module Etl
    module Meet
      class DriveSource
        QUERY = "mimeType='application/vnd.google-apps.document' and name contains 'Transcript'".freeze

        def initialize(user_email, since:)
          @user_email = user_email
          @since = since
          @service = Auth.drive_service(sub: user_email)
        end

        def each_meeting
          page = nil
          loop do
            resp = @service.list_files(
              q: "#{QUERY} and createdTime > '#{@since.utc.iso8601}'",
              fields: 'nextPageToken, files(id,name,createdTime)',
              page_token: page
            )
            Array(resp.files).each { |f| yield normalize(f) }
            page = resp.next_page_token
            break unless page
          end
        end

        private

        def normalize(file)
          text = @service.export_file(file.id, 'text/plain')
          segments = parse_segments(text)
          {
            external_id: file.id,
            title: file.name,
            url: "https://docs.google.com/document/d/#{file.id}",
            occurred_at: file.created_time,
            content_hash: Digest::SHA256.hexdigest(text.to_s),
            contacts: segments.map { |s| { email: nil, name: s[:speaker_name], role: 'speaker' } }.uniq,
            segments: segments,
            raw_metadata: { 'drive_doc_id' => file.id },
            build_source_record: ->(doc) { build_meeting(doc, file, segments) }
          }
        end

        def parse_segments(text)
          text.to_s.each_line.filter_map do |line|
            if (m = line.match(/\A\s*([^:]{1,60}):\s*(.+)\z/))
              { speaker_name: m[1].strip, speaker_email: nil, text: m[2].strip, started_at: nil, ended_at: nil }
            end
          end
        end

        def build_meeting(doc, file, segments)
          meeting = Meeting.find_or_initialize_by(drive_transcript_doc_id: file.id)
          meeting.update!(meet_source: :drive, title: file.name, started_at: file.created_time,
                          participant_count: segments.map { |s| s[:speaker_name] }.uniq.size,
                          raw_metadata: { 'document_id' => doc.id })
          meeting.segments.destroy_all
          segments.each_with_index do |s, i|
            meeting.segments.create!(position: i, speaker_name: s[:speaker_name], text: s[:text])
          end
          meeting
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/meet/drive_source_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/meet/drive_source.rb test/lib/stacks/etl/meet/drive_source_test.rb
git commit -m "feat(etl): Drive transcript backfill source"
```

---

## Task 18: Meet connector

**Files:**
- Create: `lib/stacks/etl/meet/connector.rb`
- Test: `test/lib/stacks/etl/meet/connector_test.rb`

**Interfaces:**
- Consumes: `Stacks::Etl::Connector`, `MeetApiSource`, `DriveSource`, `Classifier`.
- Produces: `Stacks::Etl::Meet::Connector.new(admin_email:, mode: :api|:drive, since: nil)` implementing `#source = :meet`, `#extract(since:)` (delegates to the chosen source, returning an Array of normalized docs), `#exclusion_for(normalized)` (delegates to `Classifier` using participant count + title). Inherits `#run`.

- [ ] **Step 1: Write the failing test**

```ruby
require 'test_helper'

class Stacks::Etl::Meet::ConnectorTest < ActiveSupport::TestCase
  setup { Stacks::Etl::Embedder.stubs(:embed).returns(vectors: [[0.5] * 1024], total_tokens: 1) }

  def normalized(id, title, pcount)
    {
      external_id: id, title: title, url: 'http://x', occurred_at: Time.utc(2026, 1, 1), content_hash: id,
      contacts: Array.new(pcount) { |i| { email: "p#{i}@x.co", name: "P#{i}", role: 'participant' } },
      segments: [{ speaker_name: 'P0', speaker_email: 'p0@x.co', text: 'decision text', started_at: Time.utc(2026, 1, 1) }],
      raw_metadata: {}, build_source_record: ->(_doc) { nil }
    }
  end

  test 'api mode ingests and classifies a 1:1 as excluded' do
    source = mock('source')
    source.stubs(:each_meeting).multiple_yields([normalized('m1', 'Gateway kickoff', 5)], [normalized('m2', 'Drew 1:1', 2)])
    Stacks::Etl::Meet::MeetApiSource.stubs(:new).returns(source)

    Stacks::Etl::Meet::Connector.new(admin_email: 'hugh@sanctuary.computer', mode: :api).run

    assert Document.find_by!(external_id: 'm1').not_excluded?
    m2 = Document.find_by!(external_id: 'm2')
    assert m2.auto_excluded?
    assert m2.reason_one_on_one?
    assert_equal 0, m2.chunks.count
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/meet/connector_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

```ruby
module Stacks
  module Etl
    module Meet
      class Connector < Stacks::Etl::Connector
        def initialize(admin_email:, mode: :api, since: nil)
          @admin_email = admin_email
          @mode = mode
          @since = since
        end

        def source = :meet

        def extract(since:)
          docs = []
          source_object(since || @since).each_meeting { |n| docs << n }
          docs
        end

        def exclusion_for(normalized)
          Classifier.call(title: normalized[:title], participant_count: normalized[:contacts].size)
        end

        private

        def source_object(since)
          if @mode == :drive
            DriveSource.new(@admin_email, since: since || 90.days.ago)
          else
            MeetApiSource.new(@admin_email)
          end
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/meet/connector_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/meet/connector.rb test/lib/stacks/etl/meet/connector_test.rb
git commit -m "feat(etl): Meet connector wiring sources + classifier"
```

---

## Task 19: Rake tasks (sync + backfill)

**Files:**
- Create: `lib/tasks/etl.rake`
- Test: `test/lib/tasks/etl_rake_test.rb`

**Interfaces:**
- Consumes: `Stacks::Etl::Meet::Connector`, `SystemTask`.
- Produces: `stacks:etl:sync_meet` (api mode), `stacks:etl:backfill_meet[days]` (drive mode, default 90), each wrapped in a `SystemTask`. Admin email from `Stacks::Utils.config[:google_oauth2]` default `hugh@sanctuary.computer`.

- [ ] **Step 1: Write the failing test**

```ruby
require 'test_helper'
require 'rake'

class EtlRakeTest < ActiveSupport::TestCase
  setup do
    Stacks::Application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task['stacks:etl:sync_meet'].reenable
  end

  test 'sync_meet runs the connector inside a SystemTask' do
    connector = mock('connector')
    connector.expects(:run).once
    Stacks::Etl::Meet::Connector.expects(:new).with(has_entry(mode: :api)).returns(connector)
    assert_difference -> { SystemTask.where(name: 'stacks:etl:sync_meet').count }, 1 do
      Rake::Task['stacks:etl:sync_meet'].invoke
    end
    assert SystemTask.where(name: 'stacks:etl:sync_meet').last.was_successful
  end
end
```

(Confirm the `SystemTask` success predicate — match whatever `stacks:sync_forecast` checks, e.g. `was_successful` / `status`.)

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/tasks/etl_rake_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement** (mirror an existing task in `lib/tasks/stacks.rake`)

```ruby
namespace :stacks do
  namespace :etl do
    desc 'Ongoing Google Meet transcript sync (Meet REST API)'
    task sync_meet: :environment do
      system_task = SystemTask.create!(name: 'stacks:etl:sync_meet')
      begin
        admin = Stacks::Utils.config.dig(:google_oauth2, :admin_email) || 'hugh@sanctuary.computer'
        Stacks::Etl::Meet::Connector.new(admin_email: admin, mode: :api).run
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end

    desc 'Backfill Google Meet transcripts from Drive (default 90 days)'
    task :backfill_meet, [:days] => :environment do |_t, args|
      system_task = SystemTask.create!(name: 'stacks:etl:backfill_meet')
      begin
        days = (args[:days] || 90).to_i
        admin = Stacks::Utils.config.dig(:google_oauth2, :admin_email) || 'hugh@sanctuary.computer'
        Stacks::Etl::Meet::Connector.new(admin_email: admin, mode: :drive, since: days.days.ago).run
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/tasks/etl_rake_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/tasks/etl.rake test/lib/tasks/etl_rake_test.rb
git commit -m "feat(etl): sync_meet + backfill_meet rake tasks (SystemTask-wrapped)"
```

---

## Task 20: Hybrid search

**Files:**
- Create: `lib/stacks/etl/search.rb`
- Test: `test/lib/stacks/etl/search_test.rb`

**Interfaces:**
- Consumes: `Chunk`, `Embedding`, `Embedder`, `Document`, `Contact`.
- Produces: `Stacks::Etl::Search.call(query:, mode: :hybrid, source: nil, contact: nil, date_range: nil, limit: 20) -> [{ chunk:, document:, score: }]`. All modes restrict to `Chunk.corpus_eligible`. `:keyword` uses tsvector; `:semantic` embeds the query (`input_type: 'query'`) and uses `nearest_neighbors`; `:hybrid` merges both by reciprocal-rank fusion. `contact` is an email or `Contact`; `date_range` filters `occurred_at`.

- [ ] **Step 1: Write the failing test**

```ruby
require 'test_helper'

class Stacks::Etl::SearchTest < ActiveSupport::TestCase
  setup do
    @doc = Document.create!(source: :meet, external_id: 'd1', occurred_at: Time.utc(2026, 1, 1), excluded: :not_excluded)
    @hit = Chunk.create!(document: @doc, position: 0, content: 'we decided to ship the gateway redesign', source: :meet)
    @miss = Chunk.create!(document: @doc, position: 1, content: 'lunch on friday', source: :meet)
    excluded_doc = Document.create!(source: :meet, external_id: 'd2', excluded: :auto_excluded)
    @excluded = Chunk.create!(document: excluded_doc, position: 0, content: 'gateway secret', source: :meet)
  end

  test 'keyword mode finds matches and excludes walled-off chunks' do
    results = Stacks::Etl::Search.call(query: 'gateway', mode: :keyword)
    ids = results.map { |r| r[:chunk].id }
    assert_includes ids, @hit.id
    refute_includes ids, @excluded.id
    refute_includes ids, @miss.id
  end

  test 'semantic mode embeds the query and ranks by neighbor distance' do
    Embedding.create!(owner: @hit, model: 'voyage-3', embedding: Array.new(1024) { 0.0 }.tap { |v| v[0] = 1.0 })
    Embedding.create!(owner: @miss, model: 'voyage-3', embedding: Array.new(1024) { 0.0 }.tap { |v| v[1] = 1.0 })
    Stacks::Etl::Embedder.expects(:embed).with(['gateway'], input_type: 'query').returns(vectors: [Array.new(1024) { 0.0 }.tap { |v| v[0] = 1.0 }], total_tokens: 1)

    results = Stacks::Etl::Search.call(query: 'gateway', mode: :semantic)
    assert_equal @hit.id, results.first[:chunk].id
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/search_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

```ruby
module Stacks
  module Etl
    class Search
      def self.call(query:, mode: :hybrid, source: nil, contact: nil, date_range: nil, limit: 20)
        base = filtered(Chunk.corpus_eligible, source: source, contact: contact, date_range: date_range)
        ids =
          case mode.to_sym
          when :keyword  then keyword_ids(base, query, limit)
          when :semantic then semantic_ids(base, query, limit)
          else fuse(keyword_ids(base, query, limit), semantic_ids(base, query, limit), limit)
          end
        chunks = Chunk.where(id: ids).includes(:document).index_by(&:id)
        ids.map { |id| chunks[id] }.compact.map { |c| { chunk: c, document: c.document, score: nil } }
      end

      def self.filtered(scope, source:, contact:, date_range:)
        scope = scope.where(source: Chunk.sources[source.to_s]) if source
        scope = scope.where(occurred_at: date_range) if date_range
        if contact
          c = contact.is_a?(Contact) ? contact : Contact.find_by(email: contact.to_s.downcase)
          scope = scope.where(speaker_contact_id: c&.id)
        end
        scope
      end

      def self.keyword_ids(scope, query, limit)
        scope.keyword_search(query).limit(limit).pluck(:id)
      end

      def self.semantic_ids(scope, query, limit)
        vector = Embedder.embed([query], input_type: 'query')[:vectors].first
        owner_ids = scope.pluck(:id)
        return [] if owner_ids.empty?
        Embedding.where(model: Embedder::MODEL, owner_type: 'Chunk', owner_id: owner_ids)
                 .nearest_neighbors(:embedding, vector, distance: 'cosine')
                 .limit(limit).map(&:owner_id)
      end

      def self.fuse(a, b, limit)
        scores = Hash.new(0.0)
        [a, b].each { |list| list.each_with_index { |id, i| scores[id] += 1.0 / (60 + i) } }
        scores.sort_by { |_id, s| -s }.first(limit).map(&:first)
      end
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/search_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/search.rb test/lib/stacks/etl/search_test.rb
git commit -m "feat(etl): hybrid keyword+semantic search (corpus-eligible only)"
```

---

## Task 21: MCP tools

**Files:**
- Create: `app/services/mcp/search_tool.rb`, `app/services/mcp/get_document_tool.rb`, `app/services/mcp/list_documents_tool.rb`, `app/services/mcp/list_sources_tool.rb`
- Test: `test/services/mcp/tools_test.rb`

**Interfaces:**
- Consumes: `Stacks::Etl::Search`, `Document`, `SourceSync`.
- Produces: four `MCP::Tool` subclasses (read-only) whose `self.call(...)` returns `MCP::Tool::Response.new([{ type: 'text', text: <json> }])`. `Mcp::SearchTool` wraps `Search`; `Mcp::GetDocumentTool` returns a corpus-eligible document + its ordered segments; `Mcp::ListDocumentsTool` lists corpus-eligible docs by filter; `Mcp::ListSourcesTool` lists `SourceSync` freshness. **Every tool restricts to `Document.corpus_eligible`.**

- [ ] **Step 1: Write the failing test**

```ruby
require 'test_helper'

class Mcp::ToolsTest < ActiveSupport::TestCase
  setup do
    @doc = Document.create!(source: :meet, external_id: 'd1', title: 'Gateway', excluded: :not_excluded)
    @chunk = Chunk.create!(document: @doc, position: 0, content: 'we decided to ship the gateway', source: :meet)
    @excluded = Document.create!(source: :meet, external_id: 'd2', title: 'Secret 1:1', excluded: :auto_excluded)
  end

  test 'search tool returns hits as json text' do
    resp = Mcp::SearchTool.call(query: 'gateway', mode: 'keyword', server_context: {})
    text = resp.content.first[:text]
    assert_includes text, 'gateway'
  end

  test 'get_document refuses an excluded document' do
    resp = Mcp::GetDocumentTool.call(id: @excluded.id, server_context: {})
    assert_includes resp.content.first[:text].downcase, 'not found'
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/services/mcp/tools_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement**

`app/services/mcp/search_tool.rb`:

```ruby
module Mcp
  class SearchTool < MCP::Tool
    description 'Search org meeting transcripts (and future sources) by keyword, semantic, or hybrid.'
    input_schema(
      properties: {
        query: { type: 'string' },
        mode: { type: 'string', enum: %w[keyword semantic hybrid] },
        source: { type: 'string' },
        contact: { type: 'string' },
        limit: { type: 'integer' }
      },
      required: ['query']
    )
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(query:, mode: 'hybrid', source: nil, contact: nil, limit: 20, server_context:)
      results = Stacks::Etl::Search.call(query: query, mode: mode.to_sym, source: source, contact: contact, limit: limit)
      payload = results.map do |r|
        { document_id: r[:document].id, title: r[:document].title, occurred_at: r[:document].occurred_at,
          speaker: r[:chunk].speaker_name, text: r[:chunk].content }
      end
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
```

`app/services/mcp/get_document_tool.rb`:

```ruby
module Mcp
  class GetDocumentTool < MCP::Tool
    description 'Fetch one corpus-eligible document with its transcript segments.'
    input_schema(properties: { id: { type: 'integer' } }, required: ['id'])
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(id:, server_context:)
      doc = Document.corpus_eligible.find_by(id: id)
      return MCP::Tool::Response.new([{ type: 'text', text: 'Document not found' }]) unless doc

      meeting = doc.source_record
      segments = meeting.is_a?(Meeting) ? meeting.segments.order(:position).map { |s| { speaker: s.speaker_name, text: s.text } } : []
      MCP::Tool::Response.new([{ type: 'text', text: { id: doc.id, title: doc.title, url: doc.url, occurred_at: doc.occurred_at, segments: segments }.to_json }])
    end
  end
end
```

`app/services/mcp/list_documents_tool.rb`:

```ruby
module Mcp
  class ListDocumentsTool < MCP::Tool
    description 'List corpus-eligible documents, optionally filtered by source.'
    input_schema(properties: { source: { type: 'string' }, limit: { type: 'integer' } })
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(source: nil, limit: 50, server_context:)
      scope = Document.corpus_eligible.order(occurred_at: :desc).limit(limit)
      scope = scope.where(source: Document.sources[source]) if source
      payload = scope.map { |d| { id: d.id, title: d.title, source: d.source, occurred_at: d.occurred_at } }
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
```

`app/services/mcp/list_sources_tool.rb`:

```ruby
module Mcp
  class ListSourcesTool < MCP::Tool
    description 'List ingested sources and their last-sync freshness.'
    input_schema(properties: {})
    annotations(read_only_hint: true, destructive_hint: false, idempotent_hint: true)

    def self.call(server_context:)
      payload = SourceSync.all.map { |s| { source: s.source, last_run_at: s.last_run_at, status: s.status, stats: s.stats } }
      MCP::Tool::Response.new([{ type: 'text', text: payload.to_json }])
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/services/mcp/tools_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/services/mcp test/services/mcp/tools_test.rb
git commit -m "feat(mcp): read-only tools (search/get/list documents/sources)"
```

---

## Task 22: MCP server endpoint (bearer auth + Streamable HTTP)

**Files:**
- Create: `app/services/mcp/server.rb`, `app/controllers/api/mcp_controller.rb`
- Modify: `config/routes.rb`
- Test: `test/integration/mcp_endpoint_test.rb`

**Interfaces:**
- Consumes: the four tools, the `mcp` gem.
- Produces: `Mcp::Server.build -> MCP::Server`; `Api::McpController#handle` authenticates `Authorization: Bearer <config token>`, logs the call, and dispatches to a stateless `StreamableHTTPTransport`. Route: `POST /api/mcp`.

- [ ] **Step 1: Confirm the transport dispatch API** for the pinned `mcp` version: check whether the controller calls `transport.handle_request(request)` or rack `transport.call(env)`. Use whichever the gem exposes (the gem's `examples/` show the canonical call). Adjust Step 3 accordingly.

- [ ] **Step 2: Write the failing test**

```ruby
require 'test_helper'

class McpEndpointTest < ActionDispatch::IntegrationTest
  setup { Stacks::Utils.stubs(:config).returns(mcp: { bearer_token: 'secret' }) }

  test 'rejects a missing/incorrect bearer token' do
    post '/api/mcp', params: {}.to_json, headers: { 'CONTENT_TYPE' => 'application/json' }
    assert_response :unauthorized
  end

  test 'accepts a tools/list JSON-RPC request with a valid token' do
    body = { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} }.to_json
    post '/api/mcp', params: body, headers: { 'CONTENT_TYPE' => 'application/json', 'Authorization' => 'Bearer secret' }
    assert_response :success
    assert_includes response.body, 'search'
  end
end
```

- [ ] **Step 3: Implement**

`app/services/mcp/server.rb`:

```ruby
module Mcp
  class Server
    def self.build
      MCP::Server.new(
        name: 'stacks_org_memory',
        version: '1.0.0',
        tools: [Mcp::SearchTool, Mcp::GetDocumentTool, Mcp::ListDocumentsTool, Mcp::ListSourcesTool]
      )
    end
  end
end
```

`app/controllers/api/mcp_controller.rb`:

```ruby
module Api
  class McpController < ActionController::API
    before_action :authenticate_bearer!

    def handle
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(Mcp::Server.build, stateless: true)
      Rails.logger.info("[mcp] #{request.remote_ip} #{request.raw_post.first(200)}")
      status, headers, body = transport.handle_request(request)  # confirm API in Step 1
      headers.each { |k, v| response.set_header(k, v) }
      render status: status, plain: Array(body).join
    end

    private

    def authenticate_bearer!
      token = request.headers['Authorization'].to_s.sub(/\ABearer /, '')
      head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(token, Stacks::Utils.config[:mcp][:bearer_token].to_s)
    end
  end
end
```

`config/routes.rb` (inside the existing `namespace :api do ... end`):

```ruby
match '/mcp', to: 'mcp#handle', via: [:post, :get, :delete]
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/integration/mcp_endpoint_test.rb`
Expected: PASS. If the transport dispatch differs in the pinned gem, adjust `#handle` per Step 1 and re-run.

- [ ] **Step 5: Commit**

```bash
git add app/services/mcp/server.rb app/controllers/api/mcp_controller.rb config/routes.rb test/integration/mcp_endpoint_test.rb
git commit -m "feat(mcp): streamable-http endpoint with bearer auth + audit log"
```

---

## Task 23: ActiveAdmin MCP menu → ETL subpages

**Files:**
- Create: `app/admin/meeting.rb`, `app/admin/document.rb`, `app/admin/chunk.rb`, `app/admin/mention.rb`, `app/admin/source_sync.rb`
- Test: `test/integration/admin_etl_test.rb`

**Interfaces:**
- Consumes: all models.
- Produces: a top-level **MCP** menu with **ETL** children. `Meeting` shows transcript segments; `Mention` exposes a `resolve` member action assigning a `Contact`; lists are filterable. (Read-mostly; resolve is the one mutation.)

- [ ] **Step 1: Write the failing test** (mirror an existing `test/integration` admin test for the auth/login helper)

```ruby
require 'test_helper'

class AdminEtlTest < ActionDispatch::IntegrationTest
  setup do
    @admin = AdminUser.create!(email: 'admin@sanctuary.computer', password: 'password12345')
    sign_in @admin  # use the project's existing Devise sign-in test helper
  end

  test 'meetings index renders under the MCP menu' do
    Meeting.create!(meet_conference_record_id: 'conferenceRecords/1', title: 'Standup', meet_source: :meet_api)
    get '/admin/meetings'
    assert_response :success
    assert_includes response.body, 'Standup'
  end

  test 'resolving a mention assigns a contact' do
    doc = Document.create!(source: :meet, external_id: 'd1')
    chunk = Chunk.create!(document: doc, position: 0, content: 'x', source: :meet)
    mention = Mention.create!(chunk: chunk, raw_text: 'Drew', status: :unresolved)
    contact = Contact.create!(email: 'drew@sanctuary.computer')
    put "/admin/mentions/#{mention.id}/resolve", params: { contact_id: contact.id }
    assert_equal contact.id, mention.reload.contact_id
    assert mention.resolved?
  end
end
```

(Confirm the project's Devise test sign-in helper — check an existing file in `test/integration`.)

- [ ] **Step 2: Run to verify it fails**

Run: `bin/rails test test/integration/admin_etl_test.rb`
Expected: FAIL

- [ ] **Step 3: Implement** (ActiveAdmin DSL; menu parent groups them under "MCP")

`app/admin/meeting.rb`:

```ruby
ActiveAdmin.register Meeting do
  menu parent: 'MCP', label: 'ETL: Meetings'
  actions :index, :show
  filter :title
  filter :meet_source
  filter :started_at

  show do
    attributes_table do
      row :title; row :organizer_email; row :started_at; row :ended_at; row :participant_count; row :meet_source
    end
    panel 'Transcript segments' do
      table_for meeting.segments.order(:position) do
        column(:position); column(:speaker_name); column(:text)
      end
    end
  end
end
```

`app/admin/document.rb`:

```ruby
ActiveAdmin.register Document do
  menu parent: 'MCP', label: 'ETL: Documents'
  actions :index, :show
  filter :source
  filter :excluded
  filter :occurred_at
  index do
    id_column
    column :source; column :title; column :occurred_at; column :excluded
    column('Chunks') { |d| d.chunks.count }
    actions
  end
end
```

`app/admin/chunk.rb`:

```ruby
ActiveAdmin.register Chunk do
  menu parent: 'MCP', label: 'ETL: Chunks'
  actions :index, :show
  filter :speaker_name
  index { id_column; column(:document); column(:position); column(:speaker_name); column(:content); actions }
end
```

`app/admin/mention.rb`:

```ruby
ActiveAdmin.register Mention do
  menu parent: 'MCP', label: 'ETL: Mentions'
  actions :index, :show
  scope('Unresolved') { |s| s.unresolved }
  scope :all
  filter :raw_text
  filter :status

  member_action :resolve, method: :put do
    resource.update!(contact_id: params[:contact_id], status: :resolved)
    redirect_to admin_mentions_path, notice: 'Mention resolved'
  end
end
```

`app/admin/source_sync.rb`:

```ruby
ActiveAdmin.register SourceSync do
  menu parent: 'MCP', label: 'ETL: Source syncs'
  actions :index, :show
  index { column :source; column :last_run_at; column :status; column(:stats) { |s| s.stats.to_json } }
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/integration/admin_etl_test.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/admin/meeting.rb app/admin/document.rb app/admin/chunk.rb app/admin/mention.rb app/admin/source_sync.rb test/integration/admin_etl_test.rb
git commit -m "feat(admin): MCP menu with ETL subpages for visual debugging"
```

---

## Final: Full suite + schema review

- [ ] Run the whole suite: `bin/rails test`
- [ ] Confirm `db/schema.rb` includes `enable_extension "vector"` and all new tables.
- [ ] Manual smoke (staging with real creds): `bin/rails 'stacks:etl:backfill_meet[7]'` then visit `/admin/meetings`; then a `tools/list` + `search` POST to `/api/mcp` with the bearer token.
- [ ] Commit any schema/annotation cleanup.

---

## Deferred to the intelligence-layer spec (do NOT build here)

`decisions`, `commitments`, `tasks`, `opportunities`, `evidence`, `events`, `links`, Notion `projects`/`milestones`, the `v_*` views, and `document_versions` (added when the first mutable source lands). Provenance hooks (chunk spans, polymorphic embeddings, mentions) already exist so these slot on without rework.
```
