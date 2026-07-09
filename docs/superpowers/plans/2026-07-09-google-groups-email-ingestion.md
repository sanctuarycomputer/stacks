# Google Groups Email Ingestion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ingest all email from every Google Group across every Workspace domain into the corpus as a new `source: google_groups`, one email **thread** per `Document`.

**Architecture:** A new `Stacks::Etl::Groups` module mirroring `Stacks::Etl::Meet`. A `GroupsSource` enumerates groups (Admin Directory), picks up to K impersonable member mailboxes per group, crawls each with the Gmail API for that group's traffic, dedups messages by RFC822 `Message-ID`, reconstructs threads from `References`, and yields normalized thread documents. The existing base `Stacks::Etl::Connector` handles find-or-create, content-hash change detection, chunking, embedding, and contact resolution unchanged. There is **no auto-exclusion** (public list addresses); `exclusion_for` inherits the base default.

**Tech Stack:** Ruby on Rails 6.1, Ruby 3.1.7, PostgreSQL + pgvector, Minitest + mocha, `google-apis-gmail_v1` + `google-apis-admin_directory_v1`, the `mail` gem (Rails-bundled) for RFC822 parsing.

## Global Constraints

- **Source enum value:** `google_groups: 2` on both `Document.source` and `Chunk.source`. Enum additions need **no migration** (integer columns already exist). The only new migration is `create_group_threads`.
- **Identity key:** `Document.external_id` = the thread's **root RFC822 `Message-ID`**. Never Gmail's `threadId` (per-mailbox). Dedup messages by `Message-ID`.
- **`occurred_at` = `first_message_at`** (thread start). Per-chunk dates come from each segment's `started_at`.
- **Gmail query:** `(list:<group> OR to:<group> OR cc:<group>)` — **never `deliveredto:`** (it matches the member's own address, not the group).
- **Keep all, no auto-exclusion:** every thread lands `not_excluded`; the `excluded` column is used only via manual human override, which already works.
- **Namespace/paths:** all new code under `lib/stacks/etl/groups/` and `test/lib/stacks/etl/groups/`, mirroring `etl/meet/`.
- **Auth:** reuse the existing service account via `Stacks::Etl::Meet::Auth`; add read-only Gmail + Directory-group scopes as **separate** service methods (do not widen the shared `SCOPES` constant used by Meet/Drive).
- **Impersonation:** Directory calls impersonate the admin (`hugh@sanctuary.computer`); Gmail calls impersonate each crawler member (`sub: member_email`).

---

## File Structure

- `db/migrate/20260709000001_create_group_threads.rb` — new `group_threads` table (the Document `source_record`).
- `app/models/group_thread.rb` — the thread source-record model.
- `app/models/document.rb` — add `google_groups: 2` to `source` enum.
- `app/models/chunk.rb` — add `google_groups: 2` to `source` enum.
- `lib/stacks/etl/meet/auth.rb` — add `gmail_service(sub:)` + `directory_group_service(sub:)` and their scope constants.
- `lib/stacks/etl/groups/workspace.rb` — `Groups::Workspace`: list groups + members via Admin Directory.
- `lib/stacks/etl/groups/message_parser.rb` — `Groups::MessageParser`: RFC822 → normalized message, and thread assembly → normalized documents.
- `lib/stacks/etl/groups/groups_source.rb` — `Groups::GroupsSource`: the crawl (`each_thread`).
- `lib/stacks/etl/groups/connector.rb` — `Groups::Connector < Stacks::Etl::Connector`.
- `lib/tasks/etl.rake` — add `sync_google_groups`, `backfill_google_groups[days]`; wire into `sync_all`.
- `Gemfile` — add `google-apis-gmail_v1`.
- `test/lib/stacks/etl/groups/*_test.rb` — tests per task.

---

## Task 1: Data model — `group_threads` table + source enums + `GroupThread`

**Files:**
- Create: `db/migrate/20260709000001_create_group_threads.rb`
- Create: `app/models/group_thread.rb`
- Modify: `app/models/document.rb:7`
- Modify: `app/models/chunk.rb:7`
- Test: `test/lib/stacks/etl/groups/group_thread_test.rb`

**Interfaces:**
- Produces: `GroupThread` (ActiveRecord) with columns `group_email:string`, `list_id:string`, `subject:string`, `root_message_id:string` (unique), `message_count:integer`, `first_message_at:datetime`, `last_message_at:datetime`. `Document.source` and `Chunk.source` both gain `:google_groups` (value `2`).

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/stacks/etl/groups/group_thread_test.rb
require 'test_helper'

class Stacks::Etl::Groups::GroupThreadTest < ActiveSupport::TestCase
  test 'Document and Chunk accept the google_groups source' do
    doc = Document.create!(source: :google_groups, external_id: '<root@x>',
                           excluded: :not_excluded, excluded_reason: :none)
    assert doc.google_groups?
    chunk = doc.chunks.create!(source: :google_groups, position: 0, content: 'hello')
    assert chunk.google_groups?
  end

  test 'GroupThread persists thread metadata keyed on root_message_id' do
    gt = GroupThread.create!(group_email: 'dev@sanctuary.computer', list_id: 'dev.sanctuary.computer',
                             subject: 'Deploy failed', root_message_id: '<root@x>',
                             message_count: 3, first_message_at: Time.utc(2026, 6, 1),
                             last_message_at: Time.utc(2026, 6, 2))
    assert_equal '<root@x>', gt.root_message_id
    assert_equal 3, gt.message_count
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/groups/group_thread_test.rb`
Expected: FAIL — `'google_groups' is not a valid source` / `uninitialized constant GroupThread`.

- [ ] **Step 3: Write the migration**

```ruby
# db/migrate/20260709000001_create_group_threads.rb
class CreateGroupThreads < ActiveRecord::Migration[6.1]
  def change
    create_table :group_threads do |t|
      t.string :group_email
      t.string :list_id
      t.string :subject
      t.string :root_message_id, null: false
      t.integer :message_count, null: false, default: 0
      t.datetime :first_message_at
      t.datetime :last_message_at
      t.timestamps
    end
    add_index :group_threads, :root_message_id, unique: true
    add_index :group_threads, :group_email
  end
end
```

- [ ] **Step 4: Write the model**

```ruby
# app/models/group_thread.rb
class GroupThread < ApplicationRecord
  has_many :documents, as: :source_record, dependent: :nullify
end
```

- [ ] **Step 5: Add the enum values**

In `app/models/document.rb`, change the `source` enum line:

```ruby
  enum source: { meet: 0, gemini_notes: 1, google_groups: 2 }
```

In `app/models/chunk.rb`, change the `source` enum line:

```ruby
  enum source: { meet: 0, gemini_notes: 1, google_groups: 2 }
```

- [ ] **Step 6: Migrate and run the test**

Run: `bin/rails db:migrate && bin/rails test test/lib/stacks/etl/groups/group_thread_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260709000001_create_group_threads.rb app/models/group_thread.rb app/models/document.rb app/models/chunk.rb db/schema.rb test/lib/stacks/etl/groups/group_thread_test.rb
git commit -m "feat(groups): group_threads table + google_groups source enum"
```

---

## Task 2: Auth — Gmail + Directory-group services

**Files:**
- Modify: `lib/stacks/etl/meet/auth.rb`
- Test: `test/lib/stacks/etl/groups/auth_test.rb`

**Interfaces:**
- Consumes: `Stacks::Etl::Meet::Auth.credentials(sub, scopes)` (existing).
- Produces: `Stacks::Etl::Meet::Auth.gmail_service(sub:) -> Google::Apis::GmailV1::GmailService`; `Stacks::Etl::Meet::Auth.directory_group_service(sub:) -> Google::Apis::AdminDirectoryV1::DirectoryService`. New constants `GMAIL_SCOPE`, `DIRECTORY_GROUP_SCOPES`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/stacks/etl/groups/auth_test.rb
require 'test_helper'

class Stacks::Etl::Groups::AuthTest < ActiveSupport::TestCase
  test 'gmail_service builds a Gmail client with read-only scope, impersonating the member' do
    fake_creds = Object.new
    Stacks::Etl::Meet::Auth.stubs(:credentials)
      .with('member@sanctuary.computer', [Stacks::Etl::Meet::Auth::GMAIL_SCOPE])
      .returns(fake_creds)
    svc = Stacks::Etl::Meet::Auth.gmail_service(sub: 'member@sanctuary.computer')
    assert_instance_of Google::Apis::GmailV1::GmailService, svc
    assert_equal fake_creds, svc.authorization
  end

  test 'directory_group_service builds a Directory client with group read-only scopes' do
    fake_creds = Object.new
    Stacks::Etl::Meet::Auth.stubs(:credentials)
      .with('admin@sanctuary.computer', Stacks::Etl::Meet::Auth::DIRECTORY_GROUP_SCOPES)
      .returns(fake_creds)
    svc = Stacks::Etl::Meet::Auth.directory_group_service(sub: 'admin@sanctuary.computer')
    assert_instance_of Google::Apis::AdminDirectoryV1::DirectoryService, svc
    assert_equal fake_creds, svc.authorization
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/groups/auth_test.rb`
Expected: FAIL — `uninitialized constant ... GMAIL_SCOPE` / `undefined method gmail_service`.

- [ ] **Step 3: Add the requires, scopes, and service methods**

At the top of `lib/stacks/etl/meet/auth.rb`, add to the existing `require` block:

```ruby
require 'google/apis/gmail_v1'
require 'google/apis/admin_directory_v1'
```

Inside `class Auth`, after the existing `CALENDAR_SCOPE` line, add:

```ruby
        GMAIL_SCOPE = Google::Apis::GmailV1::AUTH_GMAIL_READONLY
        DIRECTORY_GROUP_SCOPES = [
          Google::Apis::AdminDirectoryV1::AUTH_ADMIN_DIRECTORY_GROUP_READONLY,
          Google::Apis::AdminDirectoryV1::AUTH_ADMIN_DIRECTORY_GROUP_MEMBER_READONLY
        ].freeze
```

After the existing `calendar_service` method, add:

```ruby
        def self.gmail_service(sub:)
          service = Google::Apis::GmailV1::GmailService.new
          service.authorization = credentials(sub, [GMAIL_SCOPE])
          service
        end

        def self.directory_group_service(sub:)
          service = Google::Apis::AdminDirectoryV1::DirectoryService.new
          service.authorization = credentials(sub, DIRECTORY_GROUP_SCOPES)
          service
        end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/groups/auth_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/meet/auth.rb test/lib/stacks/etl/groups/auth_test.rb
git commit -m "feat(groups): Gmail + Directory-group auth services (read-only scopes)"
```

---

## Task 3: `Groups::Workspace` — enumerate groups + members

**Files:**
- Create: `lib/stacks/etl/groups/workspace.rb`
- Test: `test/lib/stacks/etl/groups/workspace_test.rb`

**Interfaces:**
- Consumes: `Stacks::Etl::Meet::Auth.directory_group_service(sub:)` (Task 2).
- Produces: `Groups::Workspace.all_groups -> [{ email:, name: }]`; `Groups::Workspace.members(group_email) -> [{ email:, role:, type: }]`. Both paginate and impersonate `ADMIN`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/stacks/etl/groups/workspace_test.rb
require 'test_helper'
require 'ostruct'

class Stacks::Etl::Groups::WorkspaceTest < ActiveSupport::TestCase
  test 'all_groups pages across the customer and downcases emails' do
    svc = mock('dir')
    svc.stubs(:list_groups).with(customer: 'my_customer', max_results: 200, page_token: nil)
       .returns(OpenStruct.new(groups: [OpenStruct.new(email: 'Dev@sanctuary.computer', name: 'Dev')], next_page_token: 't'))
    svc.stubs(:list_groups).with(customer: 'my_customer', max_results: 200, page_token: 't')
       .returns(OpenStruct.new(groups: [OpenStruct.new(email: 'info@index-space.org', name: 'Info')], next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:directory_group_service).returns(svc)

    groups = Stacks::Etl::Groups::Workspace.all_groups
    assert_equal [{ email: 'dev@sanctuary.computer', name: 'Dev' },
                  { email: 'info@index-space.org', name: 'Info' }], groups
  end

  test 'members returns email/role/type tuples' do
    svc = mock('dir')
    svc.stubs(:list_members).with('dev@sanctuary.computer', max_results: 200, page_token: nil)
       .returns(OpenStruct.new(members: [
         OpenStruct.new(email: 'Alice@sanctuary.computer', role: 'OWNER', type: 'USER'),
         OpenStruct.new(email: 'nested@x.com', role: 'MEMBER', type: 'GROUP')
       ], next_page_token: nil))
    Stacks::Etl::Meet::Auth.stubs(:directory_group_service).returns(svc)

    members = Stacks::Etl::Groups::Workspace.members('dev@sanctuary.computer')
    assert_equal [{ email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' },
                  { email: 'nested@x.com', role: 'MEMBER', type: 'GROUP' }], members
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/groups/workspace_test.rb`
Expected: FAIL — `uninitialized constant Stacks::Etl::Groups::Workspace`.

- [ ] **Step 3: Write the class**

```ruby
# lib/stacks/etl/groups/workspace.rb
module Stacks
  module Etl
    module Groups
      # Lists the org's Google Groups and their members via the Admin Directory API,
      # spanning every domain in the account (`customer: 'my_customer'`). Impersonates
      # the admin — group/member metadata is admin-visible, not per-mailbox.
      class Workspace
        ADMIN = 'hugh@sanctuary.computer'.freeze
        PAGE = 200

        def self.all_groups
          svc = service
          out = []
          token = nil
          loop do
            resp = svc.list_groups(customer: 'my_customer', max_results: PAGE, page_token: token)
            (resp.groups || []).each { |g| out << { email: g.email.to_s.downcase, name: g.name } }
            token = resp.next_page_token
            break unless token
          end
          out.uniq { |g| g[:email] }
        end

        def self.members(group_email)
          svc = service
          out = []
          token = nil
          loop do
            resp = svc.list_members(group_email, max_results: PAGE, page_token: token)
            (resp.members || []).each { |m| out << { email: m.email&.downcase, role: m.role, type: m.type } }
            token = resp.next_page_token
            break unless token
          end
          out
        end

        def self.service
          Stacks::Etl::Meet::Auth.directory_group_service(sub: ADMIN)
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/groups/workspace_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/groups/workspace.rb test/lib/stacks/etl/groups/workspace_test.rb
git commit -m "feat(groups): Workspace lists groups + members across all domains"
```

---

## Task 4: `Groups::MessageParser` — RFC822 parse + thread assembly

**Files:**
- Create: `lib/stacks/etl/groups/message_parser.rb`
- Test: `test/lib/stacks/etl/groups/message_parser_test.rb`

**Interfaces:**
- Produces:
  - `Groups::MessageParser.parse(raw_rfc822_string) -> Hash` with keys `:message_id, :root_id, :from_name, :from_email, :to (Array), :cc (Array), :subject, :date (Time), :body (String)`.
  - `Groups::MessageParser.assemble(group_email:, group_name:, messages:) -> Array<Hash>` — one normalized thread document per root (the exact shape `Connector#ingest` consumes: `:source, :external_id, :title, :url, :occurred_at, :content_hash, :participant_count, :contacts, :segments, :raw_metadata, :build_source_record`). `messages` is an array of `parse` hashes, already deduped by `:message_id`.

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/stacks/etl/groups/message_parser_test.rb
require 'test_helper'

class Stacks::Etl::Groups::MessageParserTest < ActiveSupport::TestCase
  P = Stacks::Etl::Groups::MessageParser

  def raw(message_id:, from:, subject:, date:, body:, references: nil, in_reply_to: nil, content_type: 'text/plain; charset=UTF-8')
    headers = +"Message-ID: #{message_id}\r\nFrom: #{from}\r\nTo: dev@sanctuary.computer\r\nSubject: #{subject}\r\nDate: #{date}\r\nContent-Type: #{content_type}\r\n"
    headers << "References: #{references}\r\n" if references
    headers << "In-Reply-To: #{in_reply_to}\r\n" if in_reply_to
    "#{headers}\r\n#{body}"
  end

  test 'parse extracts headers, address parts, and text body; root is own id when no references' do
    m = P.parse(raw(message_id: '<a@x>', from: 'Alice <alice@x.co>', subject: 'Deploy failed',
                    date: 'Mon, 01 Jun 2026 10:00:00 +0000', body: 'the api is down'))
    assert_equal '<a@x>', m[:message_id]
    assert_equal '<a@x>', m[:root_id]
    assert_equal 'Alice', m[:from_name]
    assert_equal 'alice@x.co', m[:from_email]
    assert_equal 'Deploy failed', m[:subject]
    assert_equal 'the api is down', m[:body].strip
  end

  test 'parse derives root_id from the first References entry even without the root body' do
    m = P.parse(raw(message_id: '<c@x>', from: 'Bob <bob@x.co>', subject: 'Re: Deploy failed',
                    date: 'Mon, 01 Jun 2026 11:00:00 +0000', body: 'looking now',
                    references: '<a@x> <b@x>', in_reply_to: '<b@x>'))
    assert_equal '<a@x>', m[:root_id]
  end

  test 'parse falls back to HTML->text when there is no text/plain part' do
    m = P.parse(raw(message_id: '<h@x>', from: 'Sentry <sentry@x.co>', subject: 'New issue',
                    date: 'Mon, 01 Jun 2026 12:00:00 +0000',
                    body: '<html><body><b>API-4WZ</b> DBConnection error</body></html>',
                    content_type: 'text/html; charset=UTF-8'))
    assert_includes m[:body], 'API-4WZ'
    assert_includes m[:body], 'DBConnection error'
    refute_includes m[:body], '<b>'
  end

  test 'assemble groups messages by root into one thread doc with sorted segments' do
    msgs = [
      P.parse(raw(message_id: '<a@x>', from: 'Alice <alice@x.co>', subject: 'Deploy failed',
                  date: 'Mon, 01 Jun 2026 10:00:00 +0000', body: 'the api is down')),
      P.parse(raw(message_id: '<c@x>', from: 'Bob <bob@x.co>', subject: 'Re: Deploy failed',
                  date: 'Mon, 01 Jun 2026 11:00:00 +0000', body: 'fixed it', references: '<a@x>'))
    ]
    docs = P.assemble(group_email: 'dev@sanctuary.computer', group_name: 'Dev', messages: msgs)
    assert_equal 1, docs.size
    d = docs.first
    assert_equal :google_groups, d[:source]
    assert_equal '<a@x>', d[:external_id]
    assert_equal 'Deploy failed', d[:title]
    assert_equal Time.utc(2026, 6, 1, 10), d[:occurred_at]         # first_message_at
    assert_equal ['the api is down', 'fixed it'], d[:segments].map { |s| s[:text] }
    assert_equal 'https://groups.google.com/a/sanctuary.computer/g/dev', d[:url]
    assert_equal 2, d[:participant_count]
    assert_includes d[:contacts], { email: 'dev@sanctuary.computer', name: 'Dev', role: 'group' }
    assert_includes d[:contacts], { email: 'alice@x.co', name: 'Alice', role: 'sender' }
  end

  test 'assemble content_hash changes when a reply is added (drives re-index)' do
    a = P.parse(raw(message_id: '<a@x>', from: 'Alice <alice@x.co>', subject: 'Deploy failed',
                    date: 'Mon, 01 Jun 2026 10:00:00 +0000', body: 'down'))
    c = P.parse(raw(message_id: '<c@x>', from: 'Bob <bob@x.co>', subject: 'Re: Deploy failed',
                    date: 'Mon, 01 Jun 2026 11:00:00 +0000', body: 'up', references: '<a@x>'))
    one = P.assemble(group_email: 'dev@sanctuary.computer', group_name: 'Dev', messages: [a]).first
    two = P.assemble(group_email: 'dev@sanctuary.computer', group_name: 'Dev', messages: [a, c]).first
    refute_equal one[:content_hash], two[:content_hash]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/groups/message_parser_test.rb`
Expected: FAIL — `uninitialized constant Stacks::Etl::Groups::MessageParser`.

- [ ] **Step 3: Write the parser**

```ruby
# lib/stacks/etl/groups/message_parser.rb
require 'mail'
require 'digest'

module Stacks
  module Etl
    module Groups
      # Parses raw RFC822 messages and assembles them into thread-level normalized
      # documents (the shape Stacks::Etl::Connector#ingest consumes). Keyed on the
      # RFC822 Message-ID so the same message from two crawled mailboxes dedups to one.
      class MessageParser
        REPLY_MARKER = /^On .+ wrote:\s*$/i.freeze

        def self.parse(raw)
          m = Mail.read_from_string(raw)
          refs = Array(m.references).map { |r| bracket(r) }
          in_reply = m.in_reply_to ? bracket(Array(m.in_reply_to).first) : nil
          mid = bracket(m.message_id)
          from_name, from_email = address_parts(m[:from])
          {
            message_id: mid,
            root_id: refs.first || in_reply || mid,
            from_name: from_name,
            from_email: from_email,
            to: addresses(m[:to]),
            cc: addresses(m[:cc]),
            subject: m.subject.to_s,
            date: m.date&.to_time,
            body: strip_quoted(body_text(m))
          }
        end

        # messages: parse-hashes already deduped by :message_id. Returns one doc per root.
        def self.assemble(group_email:, group_name:, messages:)
          messages.group_by { |m| m[:root_id] }.map do |root_id, msgs|
            sorted = msgs.sort_by { |m| m[:date] || Time.at(0) }
            first = sorted.first
            bodies = sorted.map { |m| m[:body] }
            {
              source: :google_groups,
              external_id: root_id,
              title: normalize_subject(first[:subject]),
              url: group_url(group_email),
              occurred_at: first[:date],
              content_hash: Digest::SHA256.hexdigest(bodies.join("\n")),
              participant_count: sorted.map { |m| m[:from_email] }.compact.uniq.size,
              contacts: contacts_for(sorted, group_email, group_name),
              segments: sorted.map { |m|
                { speaker_name: m[:from_name], speaker_email: m[:from_email],
                  text: m[:body], started_at: m[:date], ended_at: nil }
              },
              raw_metadata: {
                'group_email' => group_email,
                'list_id' => group_email.sub('@', '.'),
                'gmail_message_ids' => sorted.map { |m| m[:message_id] }
              },
              build_source_record: lambda { |doc|
                gt = GroupThread.find_or_initialize_by(root_message_id: doc.external_id)
                gt.update!(group_email: group_email, list_id: group_email.sub('@', '.'),
                           subject: normalize_subject(first[:subject]), message_count: sorted.size,
                           first_message_at: first[:date], last_message_at: sorted.last[:date])
                gt
              }
            }
          end
        end

        def self.contacts_for(sorted, group_email, group_name)
          out = [{ email: group_email, name: group_name, role: 'group' }]
          sorted.each do |m|
            out << { email: m[:from_email], name: m[:from_name], role: 'sender' } if m[:from_email]
            (m[:to] + m[:cc]).each do |addr|
              next if addr == group_email
              out << { email: addr, name: nil, role: 'recipient' }
            end
          end
          out.uniq
        end

        def self.group_url(group_email)
          local, domain = group_email.split('@', 2)
          "https://groups.google.com/a/#{domain}/g/#{local}"
        end

        def self.normalize_subject(subject)
          subject.to_s.sub(/\A((re|fwd|fw)\s*:\s*)+/i, '').strip
        end

        # Prefer text/plain; fall back to HTML->text (Sentry/Mailchimp are HTML-only and
        # ARE the signal we keep, so this branch is load-bearing).
        def self.body_text(m)
          if m.multipart?
            if m.text_part
              m.text_part.decoded
            elsif m.html_part
              strip_html(m.html_part.decoded)
            else
              ''
            end
          elsif m.mime_type == 'text/html'
            strip_html(m.decoded)
          else
            m.decoded.to_s
          end
        end

        def self.strip_html(html)
          ActionController::Base.helpers.strip_tags(html.to_s).gsub(/[ \t]+\n/, "\n").strip
        end

        # Best-effort: drop quoted-reply tails ("On ... wrote:" and >-prefixed lines) so a
        # segment holds new content, not a re-paste of the whole prior thread.
        def self.strip_quoted(text)
          lines = text.to_s.lines
          cut = lines.index { |l| l.match?(REPLY_MARKER) }
          lines = lines[0...cut] if cut
          lines.reject { |l| l.start_with?('>') }.join.strip
        end

        def self.address_parts(field)
          return [nil, nil] unless field
          addr = field.addrs.first
          addr ? [addr.display_name, addr.address&.downcase] : [nil, nil]
        rescue StandardError
          [nil, field.to_s]
        end

        def self.addresses(field)
          return [] unless field
          field.addrs.map { |a| a.address&.downcase }.compact
        rescue StandardError
          []
        end

        def self.bracket(id)
          id = id.to_s.strip
          id.start_with?('<') ? id : "<#{id}>"
        end
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/groups/message_parser_test.rb`
Expected: PASS (5 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/groups/message_parser.rb test/lib/stacks/etl/groups/message_parser_test.rb
git commit -m "feat(groups): RFC822 message parser + thread assembly"
```

---

## Task 5: `Groups::GroupsSource` — the Gmail crawl

**Files:**
- Create: `lib/stacks/etl/groups/groups_source.rb`
- Test: `test/lib/stacks/etl/groups/groups_source_test.rb`

**Interfaces:**
- Consumes: `Groups::Workspace.all_groups`, `Groups::Workspace.members(email)`, `Stacks::Etl::Meet::Workspace.all_active_user_emails` (existing — the set of impersonable internal users), `Stacks::Etl::Meet::Auth.gmail_service(sub:)`, `Groups::MessageParser.parse` / `.assemble`.
- Produces: `Groups::GroupsSource.new(admin_email:, since: nil, until_time: nil, k: 2)` with `#each_thread { |normalized| ... }`. Picks up to `k` crawler mailboxes per group (owners/managers first, restricted to active internal users), unions their group-matching messages deduped by Message-ID, and yields one normalized thread doc per root.

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/stacks/etl/groups/groups_source_test.rb
require 'test_helper'
require 'ostruct'

class Stacks::Etl::Groups::GroupsSourceTest < ActiveSupport::TestCase
  def raw(mid, from, subject, date, body, references = nil)
    h = +"Message-ID: #{mid}\r\nFrom: #{from}\r\nTo: dev@sanctuary.computer\r\nSubject: #{subject}\r\nDate: #{date}\r\nContent-Type: text/plain\r\n"
    h << "References: #{references}\r\n" if references
    "#{h}\r\n#{body}"
  end

  test 'crawls K members, dedups the same message across mailboxes, yields one thread' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer').returns([
      { email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' },
      { email: 'bob@sanctuary.computer', role: 'MEMBER', type: 'USER' },
      { email: 'nested@x.com', role: 'MEMBER', type: 'GROUP' }
    ])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails)
      .returns(['alice@sanctuary.computer', 'bob@sanctuary.computer'])

    # Both Alice and Bob received the SAME root message <a@x>; Bob also has reply <c@x>.
    root = raw('<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    reply = raw('<c@x>', 'Bob <bob@x.co>', 'Re: Deploy failed', 'Mon, 01 Jun 2026 11:00:00 +0000', 'up', '<a@x>')

    alice_gmail = mock('alice')
    alice_gmail.stubs(:list_user_messages).returns(OpenStruct.new(messages: [OpenStruct.new(id: 'g_a')], next_page_token: nil))
    alice_gmail.stubs(:get_user_message).with('me', 'g_a', format: 'raw').returns(OpenStruct.new(raw: root))

    bob_gmail = mock('bob')
    bob_gmail.stubs(:list_user_messages).returns(OpenStruct.new(messages: [OpenStruct.new(id: 'g_a2'), OpenStruct.new(id: 'g_c')], next_page_token: nil))
    bob_gmail.stubs(:get_user_message).with('me', 'g_a2', format: 'raw').returns(OpenStruct.new(raw: root))
    bob_gmail.stubs(:get_user_message).with('me', 'g_c', format: 'raw').returns(OpenStruct.new(raw: reply))

    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'alice@sanctuary.computer').returns(alice_gmail)
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'bob@sanctuary.computer').returns(bob_gmail)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 2).each_thread { |n| yielded << n }

    assert_equal 1, yielded.size, 'the duplicate root across two mailboxes must collapse to one thread'
    d = yielded.first
    assert_equal '<a@x>', d[:external_id]
    assert_equal ['down', 'up'], d[:segments].map { |s| s[:text] }
  end

  test 'a failing member mailbox does not abort the group' do
    Stacks::Etl::Groups::Workspace.stubs(:all_groups).returns([{ email: 'dev@sanctuary.computer', name: 'Dev' }])
    Stacks::Etl::Groups::Workspace.stubs(:members).with('dev@sanctuary.computer').returns([
      { email: 'alice@sanctuary.computer', role: 'OWNER', type: 'USER' },
      { email: 'bob@sanctuary.computer', role: 'MEMBER', type: 'USER' }
    ])
    Stacks::Etl::Meet::Workspace.stubs(:all_active_user_emails)
      .returns(['alice@sanctuary.computer', 'bob@sanctuary.computer'])

    root = raw('<a@x>', 'Alice <alice@x.co>', 'Deploy failed', 'Mon, 01 Jun 2026 10:00:00 +0000', 'down')
    good = mock('alice')
    good.stubs(:list_user_messages).returns(OpenStruct.new(messages: [OpenStruct.new(id: 'g_a')], next_page_token: nil))
    good.stubs(:get_user_message).returns(OpenStruct.new(raw: root))
    bad = mock('bob')
    bad.stubs(:list_user_messages).raises(Google::Apis::ClientError.new('no gmail license'))

    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'alice@sanctuary.computer').returns(good)
    Stacks::Etl::Meet::Auth.stubs(:gmail_service).with(sub: 'bob@sanctuary.computer').returns(bad)

    yielded = []
    Stacks::Etl::Groups::GroupsSource.new(admin_email: 'hugh@sanctuary.computer', k: 2).each_thread { |n| yielded << n }
    assert_equal 1, yielded.size
    assert_equal '<a@x>', yielded.first[:external_id]
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/groups/groups_source_test.rb`
Expected: FAIL — `uninitialized constant Stacks::Etl::Groups::GroupsSource`.

- [ ] **Step 3: Write the source**

```ruby
# lib/stacks/etl/groups/groups_source.rb
require 'google/apis/gmail_v1'

module Stacks
  module Etl
    module Groups
      # Crawls every group's traffic out of member mailboxes via the Gmail API.
      # Per group: pick up to K impersonable member mailboxes, search each for the
      # group's mail, dedup messages by RFC822 Message-ID, assemble threads. Memory is
      # bounded to one group's window at a time; groups are yielded lazily by the caller.
      class GroupsSource
        DEFAULT_SINCE = 30.days
        GMAIL_PAGE = 100

        def initialize(admin_email:, since: nil, until_time: nil, k: 2)
          @admin_email = admin_email
          @since = coerce(since) || DEFAULT_SINCE.ago
          @until_time = coerce(until_time)
          @k = k
        end

        def each_thread
          active = active_emails
          Workspace.all_groups.each do |g|
            crawlers = pick_crawlers(Workspace.members(g[:email]), active)
            next if crawlers.empty?
            by_id = {}
            crawlers.each do |member_email|
              fetch_group_messages(member_email, g[:email]) { |msg| by_id[msg[:message_id]] ||= msg }
            rescue StandardError => e
              Rails.logger.warn("[groups] #{g[:email]} via #{member_email} skipped: #{e.class}: #{e.message.to_s[0, 140]}")
            end
            next if by_id.empty?
            MessageParser.assemble(group_email: g[:email], group_name: g[:name], messages: by_id.values)
                         .each { |n| yield n }
          end
        end

        private

        def active_emails
          Set.new(Stacks::Etl::Meet::Workspace.all_active_user_emails)
        end

        # Owners/managers first, restricted to active internal users we can impersonate.
        def pick_crawlers(members, active)
          usable = members.select { |m| m[:type] == 'USER' && m[:email] && active.include?(m[:email]) }
          owners = usable.select { |m| %w[OWNER MANAGER].include?(m[:role]) }
          (owners + usable).map { |m| m[:email] }.uniq.first(@k)
        end

        def fetch_group_messages(member_email, group_email)
          gmail = Stacks::Etl::Meet::Auth.gmail_service(sub: member_email)
          page = nil
          loop do
            resp = gmail.list_user_messages('me', q: query_for(group_email), max_results: GMAIL_PAGE, page_token: page)
            Array(resp.messages).each do |ref|
              raw = gmail.get_user_message('me', ref.id, format: 'raw').raw
              yield MessageParser.parse(raw)
            end
            page = resp.next_page_token
            break unless page
          end
        end

        def query_for(group_email)
          q = "(list:#{group_email} OR to:#{group_email} OR cc:#{group_email})"
          q += " after:#{@since.strftime('%Y/%m/%d')}" if @since
          q += " before:#{@until_time.strftime('%Y/%m/%d')}" if @until_time
          q
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

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/groups/groups_source_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 5: Commit**

```bash
git add lib/stacks/etl/groups/groups_source.rb test/lib/stacks/etl/groups/groups_source_test.rb
git commit -m "feat(groups): GroupsSource crawls member mailboxes, dedups by Message-ID"
```

---

## Task 6: `Groups::Connector` — wire into the base lifecycle

**Files:**
- Create: `lib/stacks/etl/groups/connector.rb`
- Test: `test/lib/stacks/etl/groups/connector_test.rb`

**Interfaces:**
- Consumes: `Stacks::Etl::Connector` (base — `run`, `ingest`, `index_chunks!`), `Groups::GroupsSource`.
- Produces: `Groups::Connector.new(admin_email:, since: nil, until_time: nil, k: 2)`; `#source => :google_groups`; `#extract(since:)` returns a lazy `Enumerator`. Inherits `exclusion_for` (base default → `[:not_excluded, :none]`).

- [ ] **Step 1: Write the failing test**

```ruby
# test/lib/stacks/etl/groups/connector_test.rb
require 'test_helper'

class Stacks::Etl::Groups::ConnectorTest < ActiveSupport::TestCase
  setup do
    skip_without_pgvector # ingest creates Embedding records (pgvector column)
    Stacks::Etl::Embedder.stubs(:embed).returns(vectors: [[0.5] * 1024], total_tokens: 1)
  end

  def thread_doc(root:, bodies:, subject: 'Deploy failed')
    segs = bodies.each_with_index.map { |b, i|
      { speaker_name: 'Alice', speaker_email: 'alice@x.co', text: b, started_at: Time.utc(2026, 6, 1, 10 + i), ended_at: nil }
    }
    {
      source: :google_groups, external_id: root, title: subject,
      url: 'https://groups.google.com/a/sanctuary.computer/g/dev',
      occurred_at: Time.utc(2026, 6, 1, 10),
      content_hash: Digest::SHA256.hexdigest(bodies.join("\n")),
      participant_count: 1,
      contacts: [{ email: 'dev@sanctuary.computer', name: 'Dev', role: 'group' },
                 { email: 'alice@x.co', name: 'Alice', role: 'sender' }],
      segments: segs, raw_metadata: { 'group_email' => 'dev@sanctuary.computer' },
      build_source_record: ->(doc) {
        GroupThread.create!(root_message_id: doc.external_id, group_email: 'dev@sanctuary.computer',
                            subject: subject, message_count: bodies.size,
                            first_message_at: Time.utc(2026, 6, 1, 10), last_message_at: Time.utc(2026, 6, 1, 11))
      }
    }
  end

  test 'ingests a thread: not_excluded, chunked, embedded, with a GroupThread source_record' do
    src = mock('source')
    src.stubs(:each_thread).multiple_yields([thread_doc(root: '<a@x>', bodies: ['the api is down'])])
    Stacks::Etl::Groups::GroupsSource.stubs(:new).returns(src)

    Stacks::Etl::Groups::Connector.new(admin_email: 'hugh@sanctuary.computer').run(track: false)

    doc = Document.find_by!(source: :google_groups, external_id: '<a@x>')
    assert doc.not_excluded?, 'public group mail is never auto-excluded'
    assert doc.chunks.any?, 'eligible thread must be chunked/embedded'
    assert_equal 'GroupThread', doc.source_record_type
    assert_equal 'dev@sanctuary.computer', doc.source_record.group_email
  end

  test 'a new reply changes content_hash and re-indexes the same Document' do
    one = mock('s1')
    one.stubs(:each_thread).multiple_yields([thread_doc(root: '<a@x>', bodies: ['down'])])
    Stacks::Etl::Groups::GroupsSource.stubs(:new).returns(one)
    Stacks::Etl::Groups::Connector.new(admin_email: 'a@x.co').run(track: false)
    first_count = Document.find_by!(external_id: '<a@x>').chunks.count

    two = mock('s2')
    two.stubs(:each_thread).multiple_yields([thread_doc(root: '<a@x>', bodies: ['down', 'up and fixed now'])])
    Stacks::Etl::Groups::GroupsSource.stubs(:new).returns(two)
    Stacks::Etl::Groups::Connector.new(admin_email: 'a@x.co').run(track: false)

    assert_equal 1, Document.where(external_id: '<a@x>').count, 'same thread, one Document'
    assert_operator Document.find_by!(external_id: '<a@x>').chunks.count, :>=, first_count
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/groups/connector_test.rb`
Expected: FAIL — `uninitialized constant Stacks::Etl::Groups::Connector`.

- [ ] **Step 3: Write the connector**

```ruby
# lib/stacks/etl/groups/connector.rb
module Stacks
  module Etl
    module Groups
      class Connector < Stacks::Etl::Connector
        def initialize(admin_email:, since: nil, until_time: nil, k: 2)
          @admin_email = admin_email
          @since = since
          @until_time = until_time
          @k = k
        end

        def source = :google_groups

        def extract(since:)
          src = GroupsSource.new(admin_email: @admin_email, since: since || @since,
                                 until_time: @until_time, k: @k)
          # Lazy: assemble + ingest one group's threads at a time, not the whole org.
          Enumerator.new { |y| src.each_thread { |n| y << n } }
        end

        # No exclusion override: public list addresses -> inherit the base default
        # [:not_excluded, :none]. Manual include/exclude still works via human_locked?.
      end
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/groups/connector_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 5: Run the whole groups suite**

Run: `bin/rails test test/lib/stacks/etl/groups/`
Expected: PASS (all files green).

- [ ] **Step 6: Commit**

```bash
git add lib/stacks/etl/groups/connector.rb test/lib/stacks/etl/groups/connector_test.rb
git commit -m "feat(groups): Connector wires GroupsSource into the ETL lifecycle"
```

---

## Task 7: Rake tasks + Gemfile dep + nightly wiring

**Files:**
- Modify: `Gemfile`
- Modify: `lib/tasks/etl.rake`
- Test: `test/lib/stacks/etl/groups/rake_test.rb`

**Interfaces:**
- Consumes: `Stacks::Etl::Groups::Connector`, `SystemTask` (existing).
- Produces: rake tasks `stacks:etl:sync_google_groups` (recent, tracks cursor) and `stacks:etl:backfill_google_groups[days]` (unbounded window, `track: false`); `sync_google_groups` added to `stacks:etl:sync_all`.

- [ ] **Step 1: Add the Gemfile dependency**

In `Gemfile`, next to the other `google-apis-*` gems, add:

```ruby
gem "google-apis-gmail_v1"
```

Run: `bundle install`
Expected: bundle resolves and installs `google-apis-gmail_v1`.

- [ ] **Step 2: Write the failing test**

```ruby
# test/lib/stacks/etl/groups/rake_test.rb
require 'test_helper'

class Stacks::Etl::Groups::RakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?('stacks:etl:sync_google_groups')
    SystemTask.stubs(:create!).returns(stub(mark_as_success: true, mark_as_error: true))
  end

  def reenable(name) = Rake::Task[name].reenable

  test 'sync_google_groups runs the connector (recent, tracked)' do
    conn = mock('conn'); conn.expects(:run)
    Stacks::Etl::Groups::Connector.expects(:new).with(has_entry(admin_email: instance_of(String))).returns(conn)
    reenable('stacks:etl:sync_google_groups')
    Rake::Task['stacks:etl:sync_google_groups'].invoke
  end

  test 'backfill_google_groups passes an unbounded day window with track:false' do
    conn = mock('conn')
    conn.expects(:run).with(has_entries(track: false))
    Stacks::Etl::Groups::Connector.stubs(:new).returns(conn)
    reenable('stacks:etl:backfill_google_groups')
    Rake::Task['stacks:etl:backfill_google_groups'].invoke('3650') # 10 years — no cap
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/lib/stacks/etl/groups/rake_test.rb`
Expected: FAIL — `Don't know how to build task 'stacks:etl:sync_google_groups'`.

- [ ] **Step 4: Add the rake tasks**

In `lib/tasks/etl.rake`, inside `namespace :etl do`, after the `backfill_meet` task, add:

```ruby
    desc 'Ongoing Google Groups email sync (recent window; tracks cursor)'
    task sync_google_groups: :environment do
      system_task = SystemTask.create!(name: 'stacks:etl:sync_google_groups')
      begin
        admin = Stacks::Utils.config.dig(:google_oauth2, :admin_email) || 'hugh@sanctuary.computer'
        Stacks::Etl::Groups::Connector.new(admin_email: admin).run
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end

    desc 'Backfill Google Groups email (any number of days; default 90)'
    task :backfill_google_groups, [:days] => :environment do |_t, args|
      system_task = SystemTask.create!(name: 'stacks:etl:backfill_google_groups')
      begin
        days = (args[:days] || 90).to_i
        admin = Stacks::Utils.config.dig(:google_oauth2, :admin_email) || 'hugh@sanctuary.computer'
        # track:false so the explicit backfill window isn't written back into the ongoing cursor.
        Stacks::Etl::Groups::Connector.new(admin_email: admin).run(since: days.days.ago, track: false)
      rescue => e
        system_task.mark_as_error(e)
      else
        system_task.mark_as_success
      end
    end
```

- [ ] **Step 5: Wire into the nightly `sync_all`**

In `lib/tasks/etl.rake`, change the `sync_all` task body list from:

```ruby
      %w[stacks:etl:sync_meet_all stacks:etl:sync_gemini_notes_all].each do |task_name|
```

to:

```ruby
      %w[stacks:etl:sync_meet_all stacks:etl:sync_gemini_notes_all stacks:etl:sync_google_groups].each do |task_name|
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bin/rails test test/lib/stacks/etl/groups/rake_test.rb`
Expected: PASS (2 runs, 0 failures).

- [ ] **Step 7: Run the full groups suite + commit**

Run: `bin/rails test test/lib/stacks/etl/groups/`
Expected: all green.

```bash
git add Gemfile Gemfile.lock lib/tasks/etl.rake test/lib/stacks/etl/groups/rake_test.rb
git commit -m "feat(groups): sync/backfill rake tasks + nightly sync_all wiring"
```

---

## Post-implementation (manual, outside this plan)

- **Domain-wide delegation:** the two new scopes (`gmail.readonly`, `admin.directory.group.readonly`, plus `admin.directory.group.member.readonly`) must be authorized for the service-account client ID at https://admin.google.com/ac/owl/domainwidedelegation before the first real run. *(User confirmed this is done.)*
- **First backfill** is unbounded: run `bin/rails 'stacks:etl:backfill_google_groups[365]'` (or larger) on a Performance dyno — the local ONNX embedder needs RAM, and Gmail per-user quota scales with volume. Start with a modest window, watch `SourceSync.for('google_groups')` stats + timing, then widen.

---

## Self-Review

**Spec coverage:**
- Multi-domain group enumeration → Task 3 (`Workspace.all_groups`, `customer: 'my_customer'`).
- Gmail crawl via DWD, K members, Message-ID dedup → Task 5.
- `list: OR to: OR cc:`, no `deliveredto:` → Task 5 `query_for` (Global Constraints).
- Thread = Document, root Message-ID key, `References` root derivation, HTML fallback, quoted-strip → Task 4.
- `occurred_at = first_message_at`; per-chunk dates from segments → Task 4 + base `index_chunks!`.
- Keep all / no auto-exclusion → Task 6 (inherits base `exclusion_for`); manual override via `human_locked?` (base, unchanged).
- `content_hash` reply re-index → Task 4 (hash) + Task 6 (re-index test).
- Only new migration = `create_group_threads`; enum additions no-migration → Task 1.
- Auth scopes as separate services (don't widen shared SCOPES) → Task 2.
- Cursor + LOOKBACK + empty-cursor default → base `Connector#run` (unchanged) + Task 5 `DEFAULT_SINCE`.
- Unbounded backfill like Meet → Task 7.
- Contact roles sender/group/recipient → Task 4 `contacts_for`.
- Tests mirror `etl/meet/*_test.rb` → every task.

**Placeholder scan:** none — every step has runnable code/commands and expected output.

**Type consistency:** `parse` keys (`:message_id, :root_id, :from_name, :from_email, :to, :cc, :subject, :date, :body`) are produced in Task 4 and consumed by `assemble` (Task 4) and asserted in Task 5. The normalized-doc keys match what base `Connector#ingest` reads (`:source, :external_id, :title, :url, :occurred_at, :content_hash, :raw_metadata, :segments, :contacts, :build_source_record`) — verified against `lib/stacks/etl/connector.rb`. `GroupThread` columns used in the `build_source_record` lambda (Task 4) match the migration (Task 1). Segment keys (`:speaker_name, :speaker_email, :text, :started_at, :ended_at`) match `Chunker.call` input in `lib/stacks/etl/chunker.rb`.
