# Google Groups Email Ingestion — Design

**Goal:** Ingest **all** email from **every Google Group across every domain** in the
Workspace into the corpus as a new ETL source (`source: google_groups`), reusing the existing
`Connector` lifecycle (extract → ingest → chunk → embed). One **thread** becomes one
`Document`; its messages become `segments`. Keep everything — automated mail included — because
Sentry alerts, deploy/payment failures, and form submissions carry real signal. These are
public list addresses, so there is **no auto-exclusion**.

## Why (from a live probe)

A read-only Gmail probe of `hugh@sanctuary.computer` established:

1. **Multi-domain.** Group addresses span at least six domains in a single day of traffic —
   `dev@sanctuary.computer`, `info@`/`nyc@index-space.org`, `admin@ours.today`,
   `hello@garden3d.net`, `accounts@xxix.co`, `here@usbclub.net`. "All groups" is not
   guessable → enumerate via the **Admin Directory API** (`customer: 'my_customer'`).
2. **No read API for Group archives.** Google offers no API to read messages *out* of a Group
   (Groups Migration API is import-only; Cloud Identity / Groups Settings cover membership and
   settings, not bodies). Group mail is distributed to members' inboxes, so we crawl **member
   mailboxes** via the existing service-account + **domain-wide delegation** and filter per
   group. (Vault export is the only official full-archive path; rejected as far heavier for
   marginal gain on a search corpus. Noted as a future completeness upgrade.)
3. **`list:` wildcard does not filter.** `list:*@domain` returned essentially the whole inbox,
   so the crawl queries **per enumerated group** (`list:` / `to:` / `deliveredto:`), never a
   wildcard.
4. **Gmail `threadId` is per-mailbox.** Unioning multiple members' mailboxes means the same
   logical thread has different `threadId`s. All keying and dedup is on the **RFC822
   `Message-ID`** (globally unique); threads are reconstructed from `References`/`In-Reply-To`.

## Guiding principles

- **Keep all.** Every group thread is corpus-eligible and embedded. Automated/transactional
  mail is signal, not noise.
- **No auto-exclusion.** Public list addresses → `exclusion_for` inherits the base default
  `[:not_excluded, :none]`. The `excluded` column survives only for **manual** human override
  (`human_locked?`), which already works untouched. No `Groups::Classifier`.
- **Thread = Document.** Mirrors the Meet meeting=document / utterance=segment model, so
  `Chunker`, `MentionResolver`, and `Embedder` are reused with zero changes and a question +
  its answer stay in one retrievable unit.
- **Message-ID is the identity.** Dedup, thread assembly, and `external_id` all key on RFC822
  `Message-ID` — never Gmail's `threadId`.

## Data model

Reuse `Document` verbatim, adding:

- `Document.source` enum → `google_groups: 2` (mirror on `Chunk.source`). **No migration** —
  Rails enums are integer columns; the value is added in the model.
- New polymorphic `source_record`: **`GroupThread`** (the only new migration —
  `create_group_threads`):
  - `group_email` (string), `list_id` (string), `subject` (string)
  - `message_count` (integer), `first_message_at` / `last_message_at` (datetime)
  - `root_message_id` (string) — the RFC822 root, mirrors `Document.external_id`
  - timestamps
- **No new `excluded_reason`.**

### Normalized thread shape (yielded to `Connector#ingest`)

```ruby
{
  source: :google_groups,
  external_id: root_message_id,                 # RFC822 Message-ID of the thread root
  title: subject,                               # normalized (strip Re:/Fwd:)
  url: "https://groups.google.com/a/<domain>/g/<group-localpart>",  # group archive page (a per-thread permalink isn't derivable from Gmail)
  occurred_at: first_message_at,                # when the thread STARTED — stable; see note
  content_hash: Digest::SHA256.hexdigest(all_message_bodies_joined),  # reply => re-index
  participant_count: distinct_sender_count,     # informational only (no privacy rule here)
  contacts: [                                   # union across the thread
    { email: sender, name:, role: 'sender' },
    { email: group_email, name: group_name, role: 'group' },
    { email: recipient, name:, role: 'recipient' },  # To/Cc
  ],
  segments: [                                   # one per message, sorted by Date
    { speaker_name: from_name, speaker_email: from_addr,
      text: new_content_only, started_at: message_date, ended_at: nil },
  ],
  raw_metadata: { group_email:, list_id:, gmail_message_ids: [...] },
  build_source_record: ->(doc) { GroupThread.find_or_initialize_by(root_message_id: doc.external_id) ... },
}
```

`content_hash` covering all bodies means the base `Connector`'s "changed → re-index" path
handles late replies for free; the `LOOKBACK` re-scan catches them.

**`occurred_at` note.** Set to `first_message_at` (thread start) — stable, so a June thread with
a July reply still reads as June. Range-accurate retrieval is unaffected either way because each
`Chunk` carries its own message's `occurred_at` (from `segment.started_at`); `Document.occurred_at`
is only a thread-level display/sort field. `last_message_at` lives on `GroupThread` for freshness.

**Root-without-body note.** The root `Message-ID` is read from the `References` header of any
reply, so `external_id` is stable even when the root message itself is older than the crawl
window (or in a mailbox we didn't crawl) and thus not among the fetched segments. A later
backfill that fetches the root adds it as a segment → `content_hash` changes → re-index
(self-healing). Replies with missing/broken `References` may fragment into separate threads —
best-effort, also healed by a wider backfill.

## Extraction — `Stacks::Etl::Groups`

New sibling module `lib/stacks/etl/groups/`, mirroring `etl/meet/`:

- **`Groups::Connector < Stacks::Etl::Connector`** — `source => :google_groups`; `extract`
  returns a lazy `Enumerator` yielding one assembled thread at a time; inherits
  `exclusion_for` (base default). No override needed beyond `source` and `extract`.
- **`Groups::GroupsSource`** — the crawl:
  1. **Enumerate groups** — Directory `list_groups(customer: 'my_customer')`, paginated → all
     groups across all domains.
  2. **Pick crawlers** — `list_group_members` per group; impersonate up to **K members**
     (owners/managers first; `K` configurable, default **2**). Unioning ≥2 mailboxes closes
     "joined late / deleted it" gaps; Message-ID dedup makes the union safe.
  3. **Fetch** — per impersonated member, Gmail `users.messages.list` with
     `q = (list:<group> OR to:<group> OR cc:<group>) after:<since>`, then `messages.get`
     (full). **Not `deliveredto:`** — in a member's mailbox `Delivered-To` is the *member's*
     address, not the group, so it would never match group traffic. `list:` matches the Google
     Groups `List-ID`; `to:`/`cc:` catch messages that addressed the group directly.
  4. **Parse** — `Groups::MessageParser` (bundled `mail` gem) extracts `Message-ID`,
     `References`/`In-Reply-To`, `From`, `To`/`Cc`, `Date`, `Subject`; prefers `text/plain`,
     falls back to **HTML → text** (much automated mail — Sentry, Mailchimp — is HTML-only, and
     that's exactly the signal we want to keep, so this fallback is load-bearing, not an edge
     case); strips quoted-reply text best-effort so a segment holds new content.
  5. **Dedup + assemble** — collect messages keyed by `Message-ID` (union across members),
     group into threads via the `References` chain, sort by `Date` → `segments`; yield one
     normalized thread per group. Bounded in memory per group's window.
- **`Auth`** (extend the existing `Stacks::Etl::Meet::Auth` — already generic Google auth that
  merely lives under `meet/`): add scopes
  `admin.directory.group.readonly` + `gmail.readonly`, and `directory_service(sub:)` /
  `gmail_service(sub:)`. Add the two methods now; note a future extract to a shared
  `Stacks::Etl::Google::Auth` namespace rather than refactor mid-feature.

New Gemfile dep: **`google-apis-gmail_v1`** (Directory client already present).

**Domain-wide delegation:** the service account must be granted the two new scopes in Admin
console → Security → API Controls → Domain-wide delegation before the source can run.

## Scheduling, incremental & backfill

- **Cursor:** `SourceSync.for(:google_groups)`, same `LOOKBACK` re-scan (late replies → new
  `content_hash` → re-index). On the first run (empty cursor) `GroupsSource` applies a default
  `since` (e.g. 30 days) for the nightly, exactly like Meet; the backfill always passes an
  explicit window.
- **Rake** (`lib/tasks/etl.rake`):
  - `stacks:etl:sync_google_groups` — recent window, tracks the cursor.
  - `stacks:etl:backfill_google_groups[days]` — **unbounded**, exactly like Meet: any `days`,
    `track: false` so it never clobbers the ongoing cursor. Sensible default, no hard cap.
  - Wire `sync_google_groups` into `stacks:etl:sync_all` (error-isolated alongside the others).
- **Volume & quota:** org-wide all-history is potentially hundreds of thousands of messages. The
  embedder is local ONNX (no per-token cost), but pgvector storage and **Gmail API per-user
  quota** both scale with volume. Quota mitigation matches Meet's existing posture: rely on the
  `google-apis-core` client's built-in **retriable backoff** (transient 429/5xx) rather than a
  hand-rolled throttle (YAGNI — no explicit rate-limiter unless quota errors actually surface),
  and run large backfills as their own **windowed passes** (like the Meet backfill), not in the
  nightly job. The steady-state nightly is only a ~2-day window (the cursor advances to
  `now - LOOKBACK` each run; only the very first run uses the 30-day default), so nightly fan-out
  stays small; a full-history backfill is the one case that can burst quota — window it.
- **Error isolation:** a single group failing (deleted between enumeration and crawl, a Directory
  permissions edge, one member's revoked Gmail access) logs and is skipped — it never aborts the
  remaining groups' ingestion for that run. Isolation is layered: per-message, per-crawler-mailbox,
  and per-group.

## Testing

Minitest + mocha, mocking the Directory + Gmail services with RFC822 fixtures. Mirrors
`test/lib/stacks/etl/meet/*_test.rb`. Cover:

- Thread reconstruction from `References`/`In-Reply-To` (out-of-order arrivals, missing root).
- **Cross-mailbox dedup** by `Message-ID` (same thread from two impersonated members → one
  Document, unioned segments).
- Segment/speaker mapping (`From` → `speaker_email`/`speaker_name`), sorted by `Date`.
- `content_hash` changes when a reply lands → `Connector` re-indexes.
- Contact roles: `sender` / `group` / `recipient`.
- `text/plain` preference and quoted-reply stripping.
- Every thread lands `not_excluded` (no auto-exclusion) and is corpus-eligible.

## File layout

```
lib/stacks/etl/groups/connector.rb        # Groups::Connector < Etl::Connector
lib/stacks/etl/groups/groups_source.rb    # enumerate + crawl + dedup + assemble
lib/stacks/etl/groups/message_parser.rb   # RFC822 -> normalized message + thread assembly
lib/stacks/etl/meet/auth.rb               # + gmail_service / directory_service / scopes
app/models/group_thread.rb                # new source_record
app/models/document.rb                    # + google_groups: 2
app/models/chunk.rb                       # + google_groups: 2
db/migrate/XXXXXXXX_create_group_threads.rb
lib/tasks/etl.rake                        # sync_google_groups, backfill_google_groups[days]
Gemfile                                   # + google-apis-gmail_v1
test/lib/stacks/etl/groups/*_test.rb
```

## Out of scope (v1)

- Google Vault export path (future full-archive / compliance upgrade).
- Attachments (metadata only if cheap; body text is the corpus).
- Any auto-classification/exclusion — deferred unless a private group is later added, which a
  human handles via the existing `manually_excluded` toggle.
