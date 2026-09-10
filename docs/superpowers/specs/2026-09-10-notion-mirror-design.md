# Notion Mirror — Design

**Date:** 2026-09-10
**Status:** Approved in brainstorming (2026-09-10); revised after adversarial review the
same day; ready for implementation plan
**Supersedes:** the draft "notion read cache for stacks" (2026-09-08), whose queue,
priority tiers, probes, token bucket, and separate read API were rejected.

## Context

Stacksbot reads Notion directly through the `ntn` CLI and a handful of node scripts.
A page read is not one request: `GET /pages/:id`, then `GET /blocks/:id/children`
per 100 blocks, then one more per nested block. An agent loop that searches, reads
five results, and expands children spends 10–40 requests per page and exhausts
Notion's budget in seconds. Notion enforces **3 requests/second per connection** and
a **per-workspace limit shared by every connection**, both answered with 429 and a
`Retry-After` that can run to minutes. Stacks' own client (`lib/stacks/notion.rb`)
has no pacing and no 429 handling at all, and is pinned to API version 2021-05-13.

Evidence gathered 2026-09-10: the Stacksbot Logs DB records `exec-failed` runs on
`ntn api …` and `notion-query-dump.mjs` lasting up to 8 minutes (consistent with
Retry-After cooldowns) but carries no stderr, so the 429 attribution is strong but not
proven. The mirror removes the agent's read traffic from Notion regardless, and the
request log in `Rails.logger` (tagged `[Stacks::Notion]`) makes the next incident
diagnosable.

Workspace size the design must handle (2026-09-10): 1,269 databases visible to the
integration; Tasks 18,086 rows; Milestones 1,260; Leads 901. The dev database already
holds 23,637 `notion_pages` rows across seven databases (2,976 soft-deleted, 1,868 with
multi-run titles, none carrying `request_id`).

## Decision

Stacks becomes a **one-to-one cache of Notion**: a caching reverse proxy of Notion's
REST API, backed by tables that mirror Notion's object model (pages, blocks, data
sources, databases) as raw JSON, kept fresh by a 10-minute sweep over Notion's
workspace-wide search feed. Stacksbot reads Notion through Stacks and keeps its own
token only for writes and its deterministic config sync.

Nothing is normalized, rendered, or re-shaped on the REST surface. The only value
added is that reads are served from Postgres and never spend Notion budget twice.

### Key decisions

| Decision | Choice |
| --- | --- |
| Client | Upgrade the existing `Stacks::Notion` (HTTParty, version `2026-03-11`, pacing + Retry-After). No new class. |
| Rate limiting | Class-level per-process pacer + Retry-After honouring inside the client, same shape as `Stacks::Ghost` / `Stacks::Deel`. No shared bucket, no tiers, no request table. |
| Storage | Mirror Notion objects one-to-one: `notion_pages` (extended), `notion_blocks`, `notion_data_sources`, `notion_databases`. Raw JSON in `data`, minus `request_id`. |
| What is cached | Single objects (page, block, data source, database) and block-children levels. Queries and searches always pass through, paced, and their results warm the cache. |
| Freshness | 10-minute `stacks:notion:sweep` (Heroku Scheduler, advisory lock, `SourceSync`) over `POST /search` sorted by `last_edited_time`. Search returns full page objects, so changed properties cost 1–3 requests per run and no probes. |
| Bodies | Block trees are fetched on first read (one cursor page per web request), completed and refreshed by the sweep. |
| Read surface | `/api/notion/v1/*` — same paths, bodies, and responses as Notion, `X-Api-Key` auth. Three MCP tools mirroring Notion's MCP names on the existing `Mcp::Server`. |
| Writes | Pass through to Notion, then invalidate the touched page. |
| Job infra | Rake + Heroku Scheduler + `SystemTask`, like every other sync. |
| Corpus | Phase 3: pages with complete cached trees project into `documents` in the nightly ETL. |
| Testing | Unit tests with mocha-stubbed responses **and** a live parity test against api.notion.com proving proxy responses equal Notion's. |

## Architecture

```
stacksbot ──REST (/api/notion/v1/*)──▶ Api::Notion::ProxyController ──▶ notion_pages
          ──MCP  (notion-fetch …)───▶ Mcp::Notion*Tool ──────────────▶ notion_blocks
                                                     │ miss / stale        notion_data_sources
                                                     ▼                     notion_databases
                                            Stacks::Notion (client)            ▲
                                              pacer + Retry-After              │ upsert / mark stale
                                                     │                         │
                                                     ▼                  Stacks::Notion::Sweep
                                               api.notion.com          (10 min, search feed)
                                                                        Stacks::Notion::Webhook (phase 3)
```

### Code layout

```
lib/stacks/notion.rb                 # existing client, upgraded (see §Client)
lib/stacks/notion/ids.rb             # normalize_id: any Notion id form → dashed uuid
lib/stacks/notion/mirror.rb          # upsert_page / upsert_level / upsert_data_source / upsert_database
lib/stacks/notion/tree_fetcher.rb    # full-level walks with a wall-clock deadline (nil = no deadline)
lib/stacks/notion/sweep.rb           # search-feed sweep + stale-tree refresh (advisory lock)
lib/stacks/notion/backfill.rb        # one-off full feed walk + data source / database objects
lib/stacks/notion/reconcile.rb       # daily: full feed walk, trash / access-lost disambiguation
lib/stacks/notion/markdown.rb        # block tree → markdown (used ONLY by the notion-fetch MCP tool)
lib/stacks/notion/webhook.rb         # phase 3: signature check + event → stale flags
lib/stacks/etl/notion_pages/connector.rb   # phase 3: cached trees → documents
app/controllers/api/notion/proxy_controller.rb
app/controllers/api/notion/webhooks_controller.rb   # phase 3
app/services/mcp/notion_fetch_tool.rb
app/services/mcp/notion_search_tool.rb
app/services/mcp/notion_query_data_sources_tool.rb
app/models/notion_page.rb            # existing, extended
app/models/notion_block.rb
app/models/notion_data_source.rb
app/models/notion_database.rb
lib/tasks/notion.rake                # stacks:notion:sweep / backfill / reconcile / verify_parity
```

## Ids

Notion ids arrive in two forms: dashed uuids (API bodies, `notion_pages.notion_id`)
and dashless 32-hex strings (URLs, `ntn`, `DATABASE_IDS`, everything stacksbot will put
in a proxy path). `Stacks::Notion::Ids.normalize(id)` returns the dashed form and is
applied to **every** id on write and on every lookup path: proxy path params, MCP
arguments, the seed env var, and the `database_id`, `data_source_id`, `parent_id`, and
`page_id` columns. A unit test asserts a dashless request hits a dashed row.

## Client (`Stacks::Notion`, existing)

The class stays; its internals change.

- `NOTION_VERSION = "2026-03-11"` (Notion's latest; what stacksbot already pins).
  Under this version database rows report `parent: { type: "data_source_id",
  data_source_id, database_id }`, `in_trash` replaces `archived`, and queries go to
  `POST /data_sources/:id/query`. Verified live 2026-09-10.
- One private `request(method, path, body: nil, query: nil)` on HTTParty replaces the
  hand-rolled `Net::HTTP` calls. Every public method goes through it.
- **Pacing:** a **class-level** pacer (`Mutex` + next-slot timestamp on
  `Stacks::Notion`, not the instance, because the proxy builds a client per request)
  spaces request starts by `1.0 / NOTION_RPS` seconds. A thread claims its slot under
  the mutex and sleeps **outside** it; the Retry-After sleep never holds the mutex. Unit
  test: two threads sleeping on Retry-After do not serialize each other's slots.
- **`NOTION_RPS`** defaults to `0.6` for web dynos; Scheduler commands set their own
  (`NOTION_RPS=1.2 bin/rails stacks:notion:sweep`). Two web workers at 0.6 plus one
  rake process at 1.2 sum to 2.4/s, leaving headroom under Notion's 3/s for stacksbot's
  own writes and for overlapping `heroku run` sessions. The client's Retry-After
  handling absorbs any remaining overage.
- **429 / 529:** sleep for `Retry-After` (integer seconds; default 2 when absent;
  capped at `retry_after_cap`) and retry, up to `max_retries`. Constructor:
  `Stacks::Notion.new(max_retries: 3, retry_after_cap: 60)`. The proxy controller and
  MCP tools construct it with `max_retries: 1, retry_after_cap: 6` so a web thread
  never sleeps longer than one short cooldown. When retries are exhausted the client
  raises `Stacks::Notion::RateLimited` carrying the last response, and the proxy
  passes Notion's own 429 body and `Retry-After` header through unchanged.
- **5xx:** retry idempotent GETs with backoff (1s, 2s, 4s) up to `max_retries`; other
  errors raise `Stacks::Notion::RequestError(code, body, headers)` with the parsed
  Notion error.
- Each request logs one line: `[Stacks::Notion] GET /pages/:id 200 412ms` (plus
  `retry_after=N` on 429). This is the request log that was missing.
- Public methods: `get_page`, `get_block_children(id, start_cursor:, page_size:)`,
  `get_block`, `get_database`, `get_data_source`, `query_data_source(id, body)`,
  `search(body)`, `create_page(body)`, `update_page(id, body)`,
  `append_block_children(id, body)`, `update_block(id, body)`, `delete_block(id)`,
  `get_users`. `Stacks::Notifications#notion` keeps working unchanged.
- `sync_database(database_id)` (used by `stacks:sync_notion` for LEADS and
  HUMAN_OPERATING_MANUALS) is rewritten on top of `Stacks::Notion::Mirror.upsert_page`:
  it resolves the data source via `get_database(id)["data_sources"].first`, walks
  `query_data_source`, and **soft-deletes** rows of that `database_id` missing from
  the result (paranoid `destroy`). The reconcile predicate is `database_id`, not the
  parent-type pair (which changes shape under the new version). The rake task calls
  the two databases serially; the pacer makes `Parallel` pointless. The icon/cover/
  file-URL stripping goes away: change detection compares `last_edited_time`.

## Store

All tables hold the raw Notion object in `data` (jsonb) with the top-level
`request_id` removed on store (search and query results never carry it, GET
responses do, and it changes on every fetch). Denormalized columns exist only for
lookup and invalidation. `page_title` is the full title: every rich-text run's
`plain_text` joined, nil-safe, from whichever property has `type: "title"` (plain
pages use the key `title`).

### `notion_pages` (existing, extended)

Existing: `notion_id` (dashed uuid, unique), `notion_parent_type`, `notion_parent_id`
(both kept and written from the new parent shape), `data`, `page_title`, `deleted_at`
(acts_as_paranoid).

Added:

| column | type | purpose |
| --- | --- | --- |
| `database_id` | string, indexed | dashed database id when the page is a database row |
| `data_source_id` | string, indexed | dashed data source id when the page is a row |
| `notion_last_edited_at` | datetime, indexed | from `data["last_edited_time"]` |
| `page_fetched_at` | datetime | when `data` was last written from Notion |
| `root_children_fetched_at` | datetime | when the page's own (root-level) children list was last fully fetched |
| `tree_fetched_for_edited_at` | datetime | the page's `last_edited_time` as observed when the last complete tree walk started |
| `blocks_stale_at` | datetime, partial index | set when the swept `last_edited_time` differs from `tree_fetched_for_edited_at` |
| `recheck_after` | datetime, partial index | set when a tree walk ran within 60 s of the page's edit stamp (minute-resolution guard) |
| `wanted_at` | datetime, partial index | an MCP fetch returned `truncated`; the sweep finishes this tree first |
| `in_trash` | boolean, default false | from `data["in_trash"]` or a `page.deleted` event |
| `access_lost` | boolean, default false | 403/404 on fetch, or absent from a full reconcile and 404 on disambiguation |
| `url` | string | from `data["url"]` |

Migration backfills `database_id` from `notion_parent_id` where
`notion_parent_type = 'database_id'` (verified: all existing rows are dashed and the
LEADS / HUMAN_OPERATING_MANUALS constants match 1,018 and 94 rows), and
`notion_last_edited_at` and `page_title` from `data`.

**Scopes and deploy order.** There is no `release:` phase in the Procfile, so the slug
goes live before `db:migrate` runs. The `lead` and `human_operating_manual` scopes are
written as `where(database_id: X, in_trash: false)` and shipped **in the same deploy
that runs the migration first by hand** (`heroku run bin/rails db:migrate` before
`git push heroku`); the plan states this order. Until the version bump the parent
pair still reads `database_id`, so no dual-shape scope is needed if the migration lands
first. Consumers that keep working unchanged: `Stacks::Notion::Lead`,
`HumanOperatingManual`, `Studio#new_biz_leads`, both TaskBuilder discoveries,
`Mcp::ExploreOkrTool`, and both existing Notion test files.

**Paranoid scope.** `notion_id` is uniquely indexed with no `deleted_at` predicate, so
every upsert looks the row up with `with_deleted`. A soft-deleted row is a **cache
miss** for the proxy and MCP: the object is fetched live, upserted, and the row is
recovered iff the fetched object has `in_trash == false`. (A row soft-deleted by the
nightly `sync_database` is either trashed, which search never returns and a GET
reports as `in_trash: true`, or moved, in which case its `database_id` changes and it
leaves the Lead/HOM scopes anyway.) Trashed pages are kept as normal rows with
`in_trash = true`, served one-to-one, and excluded from the scopes.

`NotionPage#created_at` (overridden to parse `data["created_time"]`) is made nil-safe.
`NotionPage#status_history` (references a non-existent `versions` association and
`DATABASE_IDS[:TASKS]`) is deleted.

### `notion_blocks` (new)

| column | type |
| --- | --- |
| `notion_id` | string, unique |
| `parent_id` | string, indexed — the page or block whose child this is |
| `page_id` | string, indexed — the root page, for invalidation |
| `position` | integer — order within the parent's children list |
| `has_children` | boolean |
| `children_fetched_at` | datetime, null — when this block's own children list was last fully fetched |
| `data` | jsonb — the raw block object |
| timestamps | |

`children of X` = `where(parent_id: X).order(:position)`. A page's root level is
`parent_id = page_id`; its fetched marker is `notion_pages.root_children_fetched_at`.
Replacing a level is `delete where parent_id = X` then insert, in one transaction; a
block that moved within the page is keyed by `notion_id` and gets `parent_id` and
`position` updated in place rather than colliding on the unique index.

### `notion_data_sources` (new)

`notion_id` (unique), `database_id` (indexed), `title`, `data` (full object including
`properties` schema), `notion_last_edited_at`, `fetched_at`, `in_trash`, timestamps.

### `notion_databases` (new)

`notion_id` (unique), `title`, `data` (full object including `data_sources`),
`notion_last_edited_at`, `fetched_at`, `in_trash`, timestamps.

**Schema file.** `db/schema.rb` is hand-curated (it omits pgvector, `chunks.content_tsv`,
and a trigger that `test_helper.rb` recreates) and `dump_schema_after_migration` is
only disabled in production. The plan runs migrations locally with the dump
suppressed, hand-edits `schema.rb`, and diffs it for unrelated deletions before commit.

No ActiveAdmin resources are added for the new tables; the sweep's operational state
lands in `SourceSync`, which is already registered.

## Read semantics

### REST proxy — `/api/notion/v1/*`

`Api::Notion::ProxyController < ApiController`, `check_private_api_key!`, CSRF
skipped, JSON in and out. Routes are explicit; anything else is a Notion-style 404
(`{"object":"error","status":404,"code":"object_not_found",...}`). An invalid API key
renders Notion's `unauthorized` error shape with status 401.

The controller declares its own `rescue_from Stacks::Notion::RequestError,
Stacks::Notion::RateLimited` (a child handler wins over `ApiController`'s blanket
`StandardError` rescue) and renders the upstream status, body, and `Retry-After`
verbatim, without reporting to Sentry.

| Route | Served |
| --- | --- |
| `GET pages/:id` | cache hit → stored `data`. Miss (no row, soft-deleted, or `access_lost`) → `get_page`, upsert, serve. |
| `GET blocks/:id/children?start_cursor&page_size` | level cache (below). |
| `GET blocks/:id` | cache hit from `notion_blocks`; miss → live, stored if its page is known. |
| `GET data_sources/:id` | cache hit; miss → fetch, upsert. |
| `GET databases/:id` | cache hit; miss → fetch, upsert. |
| `POST data_sources/:id/query` | always pass-through (paced), one upstream request per call; returned pages are upserted. The mirror never answers a query from cache because it cannot know a data source's rows are complete. |
| `POST search` | pass-through (paced); returned pages and data sources are upserted. |
| `POST pages` | pass-through; response page upserted. |
| `PATCH pages/:id` | pass-through; response page upserted. |
| `PATCH blocks/:id/children`, `PATCH blocks/:id`, `DELETE blocks/:id` | pass-through; the owning page (resolved through the cached block or the response's `parent`) gets `blocks_stale_at = now`. |

Every response carries `X-Stacks-Cache: hit | stale | miss | live` and
`X-Stacks-Fetched-At: <iso8601>` (absent for `live`). Notion error responses (4xx)
pass through with their status, body, and `Retry-After`.

**Level cache rule.** For `children of X`:

1. Resolve X's page: X is a cached page id, or a cached block with `page_id`. If X is
   unknown, pass the request through live (paced) without storing — this only happens
   for block ids the caller did not get from us.
2. The level is **fresh** when its marker (`root_children_fetched_at` for a page,
   `children_fetched_at` for a block) is set and is later than the page's
   `blocks_stale_at` (or `blocks_stale_at` is nil).
3. Fresh → serve rows from `notion_blocks`, sliced by the caller's cursor and
   `page_size`, in Notion's list envelope (`object, results, next_cursor, has_more,
   type: "block", block: {}`).
4. Stale or never fetched → proxy **the caller's single cursor page** live (one paced
   request), upsert those block rows in place, and serve. If the request had no
   `start_cursor` and the response has `has_more: false`, the level is complete: stamp
   the marker. Multi-page levels stay live until a `TreeFetcher` walk (sweep or
   backfill, which has no deadline) completes them. A web request never fetches more
   than one upstream page for this route.
5. When a walk finds every `has_children` block in the page's tree fresh, set
   `tree_fetched_for_edited_at` to the page's `last_edited_time` observed at walk start
   and clear `blocks_stale_at` — unless the page's `notion_last_edited_at` moved during
   the walk, in which case it stays stale. If the walk started less than 60 s after
   that edit stamp, set `recheck_after = edit stamp + 60 s` so the sweep re-reads the
   page object once (1 request) after the minute boundary and re-flags it if the stamp
   moved. This is the guard for Notion's minute-resolution `last_edited_time`.

### MCP tools (existing `Mcp::Server`, same API key)

Names mirror Notion's MCP; arguments are REST-shaped because Notion's SQL/view modes
are not reproducible outside Notion. Stacksbot's read switch depends only on the REST
routes; these tools are for MCP clients (claude.ai, Claude Code).

- `notion-fetch(id)` — runs `TreeFetcher` on the page under a **6-second wall-clock
  deadline** (no request count), then returns `{ id, title, url, last_edited_time,
  properties, markdown, truncated, fetched_at }`. When the deadline passes the call
  returns what is cached with `truncated: true` and sets `wanted_at`; the next call
  resumes because the fetcher only visits levels whose marker is missing or stale, and
  the next sweep finishes `wanted_at` pages first. `markdown` comes from
  `Stacks::Notion::Markdown`, the one renderer in the system, covering paragraph,
  headings, quote, lists, to-do, toggle, callout, code, table, divider,
  image/file/bookmark/embed as links, child pages and page mentions as
  `notion://page/<id>` links, column/synced containers flattened, and
  `<!-- unsupported: type -->` for the rest.
- `notion-search(query, page_size, filter)` — pass-through to `POST /search`;
  returns Notion's results with `object, id, title, url, last_edited_time`.
- `notion-query-data-sources(data_source_id, filter, sorts, page_size, start_cursor)`
  — identical to the REST query route.

### Deviations from one-to-one (all of them)

1. The two `X-Stacks-*` headers.
2. Cached bodies omit the top-level `request_id` (and `request_status` on list
   envelopes); live pass-through responses keep them.
3. Notion file URLs (`type: "file"`) expire after ~1 hour; a cached response may carry
   an expired URL. `X-Stacks-Fetched-At` tells the caller; a write or refresh refetches.
4. A page the integration loses access to keeps serving from cache until the daily
   reconcile marks it `access_lost` (then it 404s in Notion's error shape).
5. A page trashed in Notion keeps serving with `in_trash: false` until the daily
   reconcile (search never returns trashed pages) or a `page.deleted` webhook.
6. An edit made in the same minute as a completed tree walk is caught by the
   `recheck_after` re-read on the next sweep, not immediately.
7. MCP tool arguments are REST-shaped, not Notion MCP's SQL/rows/view modes.

## Freshness

### Sweep — `stacks:notion:sweep`, every 10 minutes

`Stacks::Notion::Sweep.run_with_lock!` under `pg_try_advisory_lock` (same pattern as
`Stacks::GhostSync`), wrapped in a `SystemTask`, recording watermark and stats on
`SourceSync.for(:notion_mirror)`. Sweep, backfill, and reconcile share **one** advisory
lock key; they are mutually exclusive.

1. `POST /search`, `page_size 100`, sorted `last_edited_time` descending, no query.
   Walk cursor pages, deduping by id across pages, until a result's `last_edited_time`
   is older than `watermark - NOTION_SWEEP_OVERLAP` (env, default 5 minutes). Branch
   on `result["object"]`: `page` → `Mirror.upsert_page`, `data_source` →
   `Mirror.upsert_data_source`. For a page whose tree has been walked
   (`tree_fetched_for_edited_at` set) and whose new `last_edited_time` differs from it,
   set `blocks_stale_at`. Typical cost: 1–3 requests.
2. Re-read page objects whose `recheck_after` has passed (1 request each, bounded to
   50 per run); re-flag if the stamp moved; clear `recheck_after`.
3. Refresh trees: pages with `wanted_at` first, then `blocks_stale_at` most recently
   edited first, through `TreeFetcher` with **no per-page deadline but a run deadline
   of 5 minutes** after the sweep started. Remaining pages stay flagged.
4. Advance the watermark to `min(newest last_edited_time seen, run_started_at)`.
   Record `requests_spent`, `pages_refreshed`, `pages_still_stale` in
   `SourceSync.stats` so backlog is visible in the existing ActiveAdmin `SourceSync`
   screen.

If the scheduler was down, the next run walks the feed back to the old watermark.

### Backfill — `stacks:notion:backfill`, one-off, resumable

Walks the entire search feed (every page and data source the integration can see) and
upserts each; then fetches every data source object and its database object. Progress
(`next_cursor`, phase) lives in `SourceSync.for(:notion_backfill).cursor` so a killed
run resumes. At 1.2 req/s the feed walk is minutes; the ~1,269 data source + database
fetches are about 35 minutes. Seed trees: `NOTION_SEED_PAGE_IDS` (env, comma-separated,
any id form; default the Stacksbot control-center page
`329131fea2c780718aa8f222b25c76e8` and the Datazone page
`dc51296819394138869baaefd534816a`) get a full tree walk. Everything else fills on
first read.

### Reconcile — `stacks:notion:reconcile`, daily

Full feed walk (a few minutes). Any cached page or data source not seen and not already
`in_trash`/`access_lost` gets one `GET` to disambiguate (bounded to 200 per run):
`in_trash: true` → `in_trash = true`; 404/403 → `access_lost = true`. It also reports
pages whose mirrored `notion_last_edited_at` is older than the feed's, which is the
drift detector for the sweep overlap. The nightly `stacks:sync_notion` keeps
reconciling the two Stacks-owned databases with soft deletes, since TaskBuilder depends
on rows disappearing.

### Webhook — phase 3

`POST /api/notion/webhook` (no API key; HMAC instead). The first delivery after the
subscription is created carries `verification_token`; the controller logs it at
`warn` and the operator stores it in credentials as `notion.webhook_verification_token`
under **every** host block (`Stacks::Utils.config` is per-`BASE_HOST`). Thereafter every
delivery must satisfy `X-Notion-Signature == "sha256=" + HMAC-SHA256(raw_body, token)`;
failures are 401. Events:

| event | effect |
| --- | --- |
| `page.content_updated`, `page.properties_updated`, `page.moved`, `page.undeleted` | `blocks_stale_at = now` on the page (properties arrive via the next sweep) |
| `page.deleted` | `in_trash = true` |
| `page.created` | ignored (the sweep picks it up) |
| `data_source.schema_updated`, `data_source.content_updated` | data source `fetched_at = nil` (refetched on next read) |
| `data_source.deleted` | `in_trash = true` |

No Notion request is made from the webhook path; it returns 200 in milliseconds.
Delivery is at-most-once with retries over 24 hours, and the sweep covers the rest.

## Corpus projection — phase 3

`Stacks::Etl::NotionPages::Connector < Stacks::Etl::Connector` (not `Stacks::Etl::Notion`,
which would shadow `Stacks::Notion` inside ETL code), `source: :notion`
(`Document.source` and `Chunk.source` enums gain `notion: 3`). `extract` yields every
page with `tree_fetched_for_edited_at` set whose `notion_last_edited_at` is newer than
the document's last projection: `external_id = notion_id`, `title = page_title`, `url`,
`occurred_at = notion_last_edited_at`, `content_hash = sha256(markdown)`, segments =
markdown split on blank lines, no contacts. It is added to the explicit task list in
`stacks:etl:sync_all`, which runs as a Scheduler one-off on a dyno sized for the
embedding model. Database rows without cached trees are not projected; they are
structured data served by the query route. Exclusion policy: `not_excluded` for
everything (content shared with the integration is org content; human overrides in
ActiveAdmin still apply).

## Stacksbot changes (other repo, for completeness)

- `TOOLS.md` `## Notion` section: reads go to
  `https://stacks.garden3d.net/api/notion/v1/...` with the `X-Api-Key` header the
  Stacks MCP already uses; the same paths, bodies, and `-d @file` rules apply. Writes
  stay on `ntn api`. One added line: after a write, `GET /api/notion/v1/pages/:id`
  is fresh immediately because the proxy refetches on write.
- `scripts/notion-query-dump.mjs` and `scripts/ops-preread-dump.mjs` gain a
  `NOTION_BASE_URL` / auth-header switch pointing at Stacks.
- `sync.mjs` and the reconcilers are unchanged (their own pacer and body cache).
- `openclaw.json` `mcp.servers.stacks` already exposes the new tools.

## Error handling

- Notion 429/529 on a miss: the client sleeps ≤ `retry_after_cap`, retries once, then
  the proxy returns Notion's 429 unchanged. Cache hits never consult Notion.
- Notion 5xx on a miss: retried with backoff; then passed through.
- 403/404 on a tracked page: `access_lost = true`; the error passes through.
- Sweep failure mid-run: the watermark is only advanced after the feed walk completes;
  stale flags already written persist; `SystemTask` records the error.
- Tree fetch deadline (MCP `notion-fetch`): partial markdown + `truncated: true`;
  `wanted_at` set; the next call or sweep resumes.
- Advisory lock held (overlapping scheduler runs): the second run exits with a log line.

## Rate-limit budget

Web dynos at 0.6 req/s per process spend only on misses, stale levels, queries,
searches, and writes. One rake process at 1.2 req/s: the sweep spends 1–3 requests on
the feed, ≤ 50 on rechecks, and the rest of a 5-minute deadline on stale trees. The
3/s connection budget is respected by construction; the workspace budget is shared
with stacksbot's writes and sync and with Notion's own MCP, which this design cannot
govern.

## Testing

**Unit / integration (mocha-stubbed HTTP, `Stacks::GhostTest` pattern):**

- Client: class-level pacer spaces requests across instances; 429 sleeps `Retry-After`
  then retries; cap honoured; `RateLimited` raised after `max_retries`; 5xx retried for
  GET only; version header; two threads on Retry-After do not serialize.
- Ids: dashless and dashed inputs normalize to one key; a dashless proxy request hits a
  dashed row.
- Mirror: upsert from a page object sets `database_id`, `data_source_id`,
  `notion_last_edited_at`, full `page_title` (multi-run titles), strips `request_id`;
  a search-result object and a GET object upsert to the same row; a second upsert with
  an older `last_edited_time` never moves the row backwards; a soft-deleted row is
  found `with_deleted` and recovered only when `in_trash` is false.
- Level cache: fresh level served without a request; stale level → exactly one
  upstream request for the caller's cursor page; single-page level completes the
  marker, multi-page does not; `tree_fetched_for_edited_at` set and `blocks_stale_at`
  cleared only when the stamp did not move; `recheck_after` set for a walk within 60 s
  of the edit stamp; block moved within a page updates in place.
- Proxy: 401 in Notion's error shape without key; `X-Stacks-Cache` header per state;
  Notion 4xx passed through with status, body, and `Retry-After` and not sent to
  Sentry; writes invalidate; queries always pass through.
- Sweep: overlap catches an edit at the watermark boundary; ids deduped across cursor
  pages; watermark never passes `run_started_at`; data-source results branch to their
  table; run deadline stops tree refresh; `wanted_at` pages go first; watermark
  advances only on success.
- Renderer: fixture trees to golden markdown.
- MCP tools: `notion-fetch` truncation, `wanted_at`, and resume;
  `notion-query-data-sources` equals the REST route.
- `sync_database`: reconciles on `database_id`, soft-deletes, recovers.
- Existing tests for Lead, Human Operating Manual, TaskBuilder discoveries, and
  `ExploreOkrTool` pass unchanged after the scope switch.

**Live parity (required by the user):** `test/live/notion_parity_test.rb`, which is
collected by `bin/rails test` and therefore `skip`s as the first statement of `setup`
unless `NOTION_LIVE=1` (touching no credentials, env, or network before that guard),
plus `rake stacks:notion:verify_parity` for ad-hoc runs. Using the real dev token
against api.notion.com with `Notion-Version: 2026-03-11`, for each of: the Human
Operating Manual **setup guide** (`3bf131fea2c7809287f3c668e91d5332`, a plain page,
exercises the `title` property path), one real Leads row, the block children of both,
the Leads database (`4d9b46b8bad542509f144347db37964d`) and data source
(`8ac2bac5-bc47-4674-851e-d1b1e4f779f2`), a filtered Tasks query, and a search —

1. call Notion directly and call the proxy on a cold cache; assert the JSON bodies are
   equal ignoring `request_id` and `request_status`;
2. call the proxy again (warm); assert the body equals the cold body and
   `X-Stacks-Cache: hit`;
3. seed a row **from a search result** (the path that fills most of the mirror), then
   assert the proxy's `GET /pages/:id` equals Notion's `GET /pages/:id` ignoring
   `request_id` — this is where field-set drift between search and GET objects would
   show;
4. for the block-children route, assert the cached level equals Notion's level for
   every cursor page, including a page whose root level exceeds 100 blocks.

The parity run's output is attached to the PR. It is also run once against the Heroku
app after deploy, before stacksbot is switched.

## Deliverables outside code

- Env: `NOTION_RPS` (web config var, `0.6`), `NOTION_SEED_PAGE_IDS`,
  `NOTION_SWEEP_OVERLAP` (optional).
- Heroku Scheduler: `NOTION_RPS=1.2 bin/rails stacks:notion:sweep` every 10 minutes;
  `NOTION_RPS=1.2 bin/rails stacks:notion:reconcile` daily; `stacks:sync_notion` stays.
- One-off: `heroku run NOTION_RPS=1.2 bin/rails stacks:notion:backfill`, re-run until
  it reports complete.
- Deploy order for phase 1: migrate, then release.
- Phase 3: create the webhook subscription in Notion's integration settings against
  the production URL; capture the verification token into credentials for every host.

## Rollout

1. **Client + schema** — upgrade `Stacks::Notion`, migrations and hand-curated
   `schema.rb`, scope switch, delete dead code, `sync_notion` on the new upsert with
   soft deletes on `database_id`. Full suite green. Migrate, then deploy.
2. **Mirror + reads** — `Ids`, `Mirror`, `TreeFetcher`, proxy controller, MCP tools,
   renderer, `Sweep`, `Backfill`, `Reconcile`, rake tasks, live parity test. Deploy;
   add the Scheduler jobs; run backfill; run parity against prod; switch stacksbot's
   read paths.
3. **Freshness + corpus** — webhook endpoint and subscription, ETL connector in
   `sync_all`.

## Generic pattern (for the next external service)

Stacks already mirrors Forecast, Runn, QBO, and Deel into tables and reads them from
MCP tools. Notion adds the three pieces that make a mirror safe to expose to an agent:

1. **One client, one pacer** — every request to the service goes through a single
   client method that paces and honours the service's retry signal.
2. **Freshness on the response** — every read says when the row was fetched and
   whether the mirror knows it is stale.
3. **Fill on miss** — a read that finds nothing fetches through the client, stores,
   and serves, so the mirror grows with what the agent actually asks for instead of
   needing a full crawl up front.

## Open items for the implementation plan

- `RACK_TIMEOUT_SERVICE_TIMEOUT` is not set in the repo; the 6 s deadlines assume the
  gem's 15 s default on Heroku. Confirm on the app before deploy.
- Notion's search-index lag is unmeasured; the 5-minute overlap is an env var and the
  daily reconcile reports drift so it can be tuned.
- Whether Stacks and stacksbot share one integration token is unknown; it decides
  whether stacksbot's writes share the 3/s connection budget with this mirror. Either
  way the design holds.
