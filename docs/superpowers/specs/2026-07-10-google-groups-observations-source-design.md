# Google Groups as an Observations Source — Design

**Goal:** Make the Google Groups email corpus an *observed* source in stacksbot, so its salient
signals (leads, client/partner risks, decisions, unanswered asks) land as rows in the Notion
Observations DB — alongside the existing (drafted) Twist/corpus observation machinery. Each
observation carries an **accurate backlink to the exact email thread**.

Two repos:
- **Part A — `stacks` (this repo):** one small MCP addition so an observing agent can build the
  precise backlink. Shipped as a normal PR (TDD).
- **Part B — `stacksbot` + Notion:** author a `google-groups` Sources row (the `## Fetch`
  contract) and a disabled `Observe: Google Groups` Job, and tune the salience rubric for email.
  No stacksbot *code* — the sync reconcilers materialize Notion rows into the always-loaded
  `sources` skill; the `observe` skill (source-agnostic) reads the contract.

## Why (decisions already made)

- **The corpus is already exposed via MCP, source-agnostically.** `search` / `list_documents` /
  `get_document` query `corpus_eligible` across all sources; `google_groups` (~39k threads,
  backfilled) is already searchable/retrievable. No change needed for retrieval — only for
  *observing*.
- **The observations system lives in `stacksbot`, not here.** It reads this corpus via the
  read-only stacks MCP, applies a salience rubric, and writes rows to a Notion Observations DB.
  Adding a source = a Notion Sources row + an Observe Job + rubric tuning (the Twist pattern).
- **Scope: all groups, rubric filters noise.** No denylist. The ongoing job works a bounded
  rolling window, and the rubric treats automated/notification mail (Sentry, CI/deploy,
  QuickBooks, Mailchimp, `no-reply@`) as low-salience so it is rejected fast. (`dev@` + `admin@`
  are ~60% of volume and almost pure automation — they'll mostly produce nothing, which is fine.)
- **Forward-only to start.** Enable the daily rolling-window job now; defer the ~39k historical
  backfill until the rubric's yield is proven. (A historical backfill is a later, separate
  Workflow.)
- **Grain: thread-level.** One observation per salient thread. Source Key
  `stacks:groups:<root_message_id>` (deterministic → overlapping windows dedup naturally).
- **Backlink: accurate.** Primary Source Ref is the Gmail `rfc822msgid` deep link (opens the
  exact thread, built from the RFC822 `root_message_id` we store). Secondary is the group
  archive page (`get_document`'s existing `url`). Because the accurate link carries the group
  context on click, the `Source` tag stays the plain value **"Google Groups"** — no per-group
  tag, no select-option sprawl.
  - *Honest caveat:* the Gmail link opens in the viewer's own Gmail and resolves for anyone who
    received that list's mail (i.e. the internal team, who are largely on these lists). It is not
    a universally-resolvable public permalink — a true Google Groups per-thread permalink is not
    derivable from Gmail data (the conversation id is a Groups-internal token we never receive).

## Part A — `stacks` MCP change (the only code here)

`get_document` already returns `{ id, title, url, occurred_at, meeting_key, segments, body }`,
and for a Groups doc `url` is already the group archive page. The observing agent additionally
needs the RFC822 root Message-ID to build the precise Gmail link. That value is
`Document#external_id` for `google_groups` docs.

**Change:** `app/services/mcp/get_document_tool.rb` — add `source` (generally useful) and, for
Groups docs, `root_message_id` to the response:

```ruby
extra = doc.google_groups? ? { root_message_id: doc.external_id } : {}
Responses.ok({ id: doc.id, title: doc.title, url: doc.url, occurred_at: doc.occurred_at,
               source: doc.source, meeting_key: meeting_key, segments: segments, body: body }
             .merge(extra))
```

- `segments: []` and `meeting_key: nil` for Groups docs (unchanged — email isn't speaker-
  segmented and its `source_record` is a `GoogleGroupThread`, not a `Meeting`). The observe
  agent reads `body`.
- `list_documents` is **unchanged** — it already accepts `source:` + `occurred_after:` and
  returns `{ id, title, source, occurred_at }`, which is all the enumeration step needs.
- **Not doing:** changing `Document#url` to the Gmail link (would need a 39k-row backfill and
  alters existing search citations — YAGNI; the agent builds the Gmail link from
  `root_message_id`). `group_email` is **not** exposed — `url` already carries the group.

**Test** (`test/services/mcp/get_document_tool_test.rb` or the existing MCP tool tests):
a `google_groups` Document's `get_document` response includes `root_message_id == external_id`
and `source == "google_groups"`; a `meet` Document's response omits `root_message_id` and still
carries `meeting_key`/`segments`.

### The window wrinkle (accepted for v1)

`Document#occurred_at` = the thread's **first** message date (deliberate). So
`list_documents(occurred_after: <7d>)` catches threads that *started* in the window and will
**miss** an old thread that gets a fresh reply today. Acceptable for v1 (most salient email
threads start and resolve within days) and keeps cost bounded. Fixing it later = a small
stacks-side change to filter/expose `GoogleGroupThread#last_message_at`; out of scope here.

## Part B — stacksbot / Notion authoring

### B1. Sources DB row — `Google Groups`

New row in the stacksbot Sources DB (`9090b15496114236ba7a641d660c6e8c`):
`Name: Google Groups` · `Slug: google-groups` · `Backing Tool: stacks MCP` ·
`Cite Label: Google Groups` · `Status: Draft`. Body:

```markdown
## Fetch
Enumerate recent Google Groups email threads via the stacks MCP:
- list_documents(source: "google_groups", occurred_after: <now − 7 days>), paging by offset
  until fewer than `limit` come back.
- For each id, get_document(id) → { title, url, occurred_at, root_message_id, body }.
Normalize each thread to { id: root_message_id, timestamp: occurred_at, text: body,
  url: <Source Ref below> }. Sender attribution isn't exposed for email (segments: []); judge
  salience on `body`, and treat the group (from `url`) as context.
Automated/notification mail — Sentry, CI/deploy, QuickBooks/Intuit, Mailchimp, calendar
invites, `no-reply@`/`notifications@` senders — is LOW salience: reject fast unless the body
carries a genuine decision, commitment, risk, or an ask directed at the team.

## Source Key
stacks:groups:<root_message_id>

## Source Ref
Primary (exact thread): https://mail.google.com/mail/#search/rfc822msgid:<URL-encoded root_message_id>
Secondary (browse in Google Groups): the document's `url` (the group's archive page).

## Search   (stub — for future Recall)
stacks MCP search(query, source: "google_groups", mode: "hybrid", limit: 8); fall back to
keyword mode if semantic times out.

## Cite     (stub — for future Recall)
Same two links as Source Ref.
```

`Source` value written on each Observation = **"Google Groups"** (matches `Cite Label`; one new
select option on the Observations DB `Source` property).

### B2. Observe Job — `Observe: Google Groups`

New row in the stacksbot Jobs DB (`329131fea2c78015ba3eed7476974b9b`):
`Name: Observe: Google Groups` · `Cron: 0 6 * * *` (daily 06:00 ET — email is lower-velocity than
Twist) · `Deliver To: none` (silent) · **disabled** (Enable unchecked). Body:

```markdown
# Observe: Google Groups
## Procedure
1. Load the `observe` skill.
2. Run it for source `google-groups`.
## Output
New rows in Observations DB (390131fea2c7808bb216c38b46c3ba55).
## Deliver To
none
```

### B3. Rubric tuning

The `observe` skill's salience rubric already excludes routine chatter. Add one email-specific
line (in the skill, in Notion): *automated/transactional/notification mail is low-salience;* and
one inclusion emphasis: *inbound inquiries on `hello@`/`info@`-type lists are lead signals — the
exact thing to record.* No structural change to the rubric.

### B4. Activation

Author B1–B3 as **Draft/disabled**. They go live when the `observe` machinery is enabled
org-wide (it isn't yet — Google Groups would be among the first corpus sources observed). This
stages the source and validates the corpus→observe path without turning on an autonomous sensor
prematurely.

## Testing / validation

- **Part A:** unit test on the `get_document` response (above); manual MCP call against a real
  `google_groups` doc confirms `root_message_id` present and the Gmail `rfc822msgid` link opens
  the thread.
- **Part B:** with the source enabled in a controlled run — (1) run `observe` for `google-groups`
  once, confirm salient threads become Observations with `Source Key stacks:groups:<root>`,
  `Source = Google Groups`, and a working Gmail backlink; (2) re-run immediately with no new
  activity → **zero** new rows (deterministic-key idempotence); (3) confirm an automated
  Sentry/QuickBooks thread is rejected (no observation).

## Out of scope (v1)

- Historical backfill of the ~39k threads (later Workflow).
- Last-activity windowing (`GoogleGroupThread#last_message_at`) — v1 windows on thread start.
- Per-message grain and thread-*state* observations (Twist's `:idle`-style keys).
- Sender attribution via MCP (`document_contacts`) — judge on `body` for v1.
- Recall wiring (the `## Search`/`## Cite` stubs are authored but Recall itself is separate).
