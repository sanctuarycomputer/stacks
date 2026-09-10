# Notion Mirror — Design

**Date:** 2026-09-10
**Status:** Approved in brainstorming (2026-09-10), ready for implementation plan
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
integration; Tasks 18,086 rows; Milestones 1,260; Leads 901.

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
| Rate limiting | Per-process pacer + Retry-After honouring inside the client, same shape as `Stacks::Ghost` / `Stacks::Deel`. No shared bucket, no tiers, no request table. |
| Storage | Mirror Notion objects one-to-one: `notion_pages` (extended), `notion_blocks`, `notion_data_sources`, `notion_databases`. Raw JSON in `data`. |
| Freshness | 10-minute `stacks:notion:sweep` (Heroku Scheduler, advisory lock, `SourceSync`) over `POST /search` sorted by `last_edited_time`. Search returns full page objects, so changed properties cost 1–3 requests per run and no probes. |
| Bodies | Block trees are fetched on first read, cached per level, and refetched when the page's edit time moves. |
| Read surface | `/api/notion/v1/*` — same paths, bodies, and responses as Notion, `X-Api-Key` auth. Three MCP tools mirroring Notion's MCP names on the existing `Mcp::Server`. |
| Writes | Pass through to Notion, then invalidate the touched page. |
| Job infra | Rake + Heroku Scheduler + `SystemTask`, like every other sync. |
| Corpus | Phase 3: pages with cached trees project into `documents` in the nightly ETL. |
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
lib/stacks/notion/mirror.rb          # upsert_page / upsert_blocks / upsert_data_source / upsert_database
lib/stacks/notion/tree_fetcher.rb    # level-by-level block fetch with a request budget
lib/stacks/notion/sweep.rb           # search-feed sweep + stale-tree refresh (advisory lock)
lib/stacks/notion/backfill.rb        # one-off full feed walk + data source / database schemas
lib/stacks/notion/markdown.rb        # block tree → markdown (used ONLY by the notion-fetch MCP tool)
lib/stacks/notion/webhook.rb         # phase 3: signature check + event → stale flags
lib/stacks/etl/notion/connector.rb   # phase 3: cached trees → documents
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

## Client (`Stacks::Notion`, existing)

The class stays; its internals change.

- `NOTION_VERSION = "2026-03-11"` (Notion's latest; what stacksbot already pins).
  Under this version database rows report `parent: { type: "data_source_id",
  data_source_id, database_id }`, `in_trash` replaces `archived`, and queries go to
  `POST /data_sources/:id/query`. Verified live 2026-09-10.
- One private `request(method, path, body: nil, query: nil)` on HTTParty replaces the
  hand-rolled `Net::HTTP` calls. Every public method goes through it.
- **Pacing:** a process-wide pacer (`Mutex` + next-slot timestamp) spaces request
  starts by `1.0 / NOTION_RPS` seconds. `NOTION_RPS` defaults to `1.0`; two Puma
  workers plus the sweep sum to Notion's 3/s. The value is an env var so it can be
  tuned per dyno.
- **429 / 529:** sleep for `Retry-After` (integer seconds; default 2 when absent;
  capped at `retry_after_cap`) and retry, up to `max_retries`. Constructor:
  `Stacks::Notion.new(max_retries: 3, retry_after_cap: 60)`. The proxy controller and
  MCP tools construct it with `max_retries: 1, retry_after_cap: 8` so a web thread
  never sleeps longer than one short cooldown. When retries are exhausted the client
  raises `Stacks::Notion::RateLimited` carrying the last response, and the proxy
  passes Notion's own 429 body and `Retry-After` header through unchanged.
- **5xx:** retry idempotent GETs with backoff (1s, 2s, 4s) up to `max_retries`; other
  errors raise `Stacks::Notion::RequestError(code, body)` with the parsed Notion error.
- Each request logs one line: `[Stacks::Notion] GET /pages/:id 200 412ms` (plus
  `retry_after=N` on 429). This is the request log that was missing.
- Public methods: `get_page`, `get_block_children(id, start_cursor:, page_size:)`,
  `get_block`, `get_database`, `get_data_source`, `query_data_source(id, body)`,
  `search(body)`, `create_page(body)`, `update_page(id, body)`,
  `append_block_children(id, body)`, `update_block(id, body)`, `delete_block(id)`,
  `get_users`. Existing callers (`sync_database`, `Stacks::Notifications#notion`) keep
  working; `query_database` becomes `query_data_source` after resolving the data
  source via `get_database(...)["data_sources"].first`.
- `sync_database(database_id)` (used by `stacks:sync_notion` for LEADS and
  HUMAN_OPERATING_MANUALS) is rewritten on top of `Stacks::Notion::Mirror.upsert_page`
  and **soft-deletes** rows missing from the query (paranoid `destroy`) instead of
  `delete_all`. The icon/cover/file-URL stripping goes away: change detection now
  compares `last_edited_time`, not a Hashdiff of the blob.

## Store

All tables hold the raw Notion object in `data` (jsonb). Denormalized columns exist
only for lookup and invalidation.

### `notion_pages` (existing, extended)

Existing: `notion_id` (dashed uuid, unique), `notion_parent_type`, `notion_parent_id`,
`data`, `page_title`, `deleted_at` (acts_as_paranoid).

Added:

| column | type | purpose |
| --- | --- | --- |
| `object` | string, default `page` | always `page` today; reserved |
| `database_id` | string, indexed | dashed database id when the page is a database row |
| `data_source_id` | string, indexed | dashed data source id when the page is a row |
| `notion_last_edited_at` | datetime, indexed | from `data["last_edited_time"]` |
| `page_fetched_at` | datetime | when `data` was last written from Notion |
| `root_children_fetched_at` | datetime | when the page's own (root-level) children list was last fetched |
| `blocks_stale_at` | datetime, partial index | set when Notion's edit time passes the cached tree |
| `tree_complete_at` | datetime | last time every `has_children` block in the tree had children fetched |
| `in_trash` | boolean, default false | from `data["in_trash"]` or a `page.deleted` event |
| `access_lost` | boolean, default false | 403/404 on fetch, or absent from a full reconcile |
| `url` | string | from `data["url"]` |

Migration backfills `database_id` from `notion_parent_id` where
`notion_parent_type = 'database_id'`, and `notion_last_edited_at` from `data`.

The `lead` and `human_operating_manual` scopes switch from
`(notion_parent_type, notion_parent_id)` to `database_id`, which is what keeps
`Stacks::Notion::Lead`, `HumanOperatingManual`, `Studio#new_biz_leads`, TaskBuilder,
and `Mcp::ExploreOkrTool` working across the version bump. `NotionPage#status_history`
(references a non-existent `versions` association and `DATABASE_IDS[:TASKS]`) is
deleted.

### `notion_blocks` (new)

| column | type |
| --- | --- |
| `notion_id` | string, unique |
| `parent_id` | string, indexed — the page or block whose child this is |
| `page_id` | string, indexed — the root page, for invalidation |
| `position` | integer — order within the parent's children list |
| `has_children` | boolean |
| `children_fetched_at` | datetime, null — when this block's own children list was last fetched |
| `data` | jsonb — the raw block object |
| timestamps | |

`children of X` = `where(parent_id: X).order(:position)`. A page's root level is
`parent_id = page_id`; its fetched marker is `notion_pages.root_children_fetched_at`.

### `notion_data_sources` (new)

`notion_id` (unique), `database_id` (indexed), `title`, `data` (full object including
`properties` schema), `notion_last_edited_at`, `fetched_at`, `in_trash`, timestamps.

### `notion_databases` (new)

`notion_id` (unique), `title`, `data` (full object including `data_sources`),
`notion_last_edited_at`, `fetched_at`, `in_trash`, timestamps.

`db/schema.rb` is hand-curated in this repo; new tables and columns are added to it
in the same commit as the migration.

## Read semantics

### REST proxy — `/api/notion/v1/*`

`Api::Notion::ProxyController < ApiController`, `check_private_api_key!`, CSRF
skipped, JSON in and out. Routes are explicit; anything else is a Notion-style 404
(`{"object":"error","status":404,"code":"object_not_found",...}`).

| Route | Served |
| --- | --- |
| `GET pages/:id` | cache hit → stored `data`. Miss → `get_page`, upsert, serve. |
| `GET blocks/:id/children?start_cursor&page_size` | level cache (below). |
| `GET blocks/:id` | cache hit from `notion_blocks`; miss → live, cached if its page is known. |
| `GET data_sources/:id` | cache hit; miss → fetch, upsert. |
| `GET databases/:id` | cache hit; miss → fetch, upsert. |
| `POST data_sources/:id/query` | body has no `filter` and no `sorts` → cached rows for that data source, `in_trash = false`, ordered `notion_last_edited_at desc`, paginated by an opaque `start_cursor`, `page_size ≤ 100`, in Notion's list envelope. Otherwise pass-through (paced); returned pages are upserted. |
| `POST search` | pass-through (paced); returned pages and data sources are upserted. |
| `POST pages` | pass-through; response page upserted. |
| `PATCH pages/:id` | pass-through; response page upserted. |
| `PATCH blocks/:id/children`, `PATCH blocks/:id`, `DELETE blocks/:id` | pass-through; the owning page gets `blocks_stale_at = now`. |

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
   `page_size`, in Notion's list envelope. Stale or never fetched → fetch every page of
   that level from Notion (`page_size 100` until `has_more` is false), replace the
   level's rows, stamp the marker, serve. One level costs 1 request per 100 blocks;
   a first page read costs the same as it does today through `ntn`, paid once.
4. After a level fetch, if every `has_children` block in the page's tree has a fresh
   marker, set `tree_complete_at = now` and clear `blocks_stale_at`.

### MCP tools (existing `Mcp::Server`, same API key)

Names mirror Notion's MCP; arguments are REST-shaped because Notion's SQL/view modes
are not reproducible outside Notion.

- `notion-fetch(id)` — ensures the page's whole tree is fresh via
  `Stacks::Notion::TreeFetcher` under a request budget (20 requests / 10 s wall per
  call), then returns `{ id, title, url, last_edited_time, properties, markdown,
  truncated, fetched_at }`. When the budget runs out the call returns what is cached
  with `truncated: true`; the next call resumes because the fetcher only visits blocks
  whose marker is missing or stale. `markdown` comes from `Stacks::Notion::Markdown`,
  the one renderer in the system, covering paragraph, headings, quote, lists, to-do,
  toggle, callout, code, table, divider, image/file/bookmark/embed as links, child
  pages and page mentions as `notion://page/<id>` links, column/synced containers
  flattened, and `<!-- unsupported: type -->` for the rest.
- `notion-search(query, page_size, filter)` — pass-through to `POST /search`;
  returns Notion's results with `object, id, title, url, last_edited_time`.
- `notion-query-data-sources(data_source_id, filter, sorts, page_size, start_cursor)`
  — identical to the REST query route.

### Deviations from one-to-one (all of them)

1. The two `X-Stacks-*` headers.
2. `request_id` in a cached body is the id of the request that filled the cache.
3. Notion file URLs (`type: "file"`) expire after ~1 hour; a cached response may carry
   an expired URL. `X-Stacks-Fetched-At` tells the caller; a write or refresh refetches.
4. An unfiltered, unsorted query is served in `last_edited_time desc` order rather than
   Notion's manual order. Callers that need Notion's order pass `sorts`.
5. A page the integration loses access to keeps serving from cache until the weekly
   reconcile marks it `access_lost` (then it 404s in Notion's error shape).
6. MCP tool arguments are REST-shaped, not Notion MCP's SQL/rows/view modes.

## Freshness

### Sweep — `stacks:notion:sweep`, every 10 minutes

`Stacks::Notion::Sweep.run_with_lock!` under `pg_try_advisory_lock` (same pattern as
`Stacks::GhostSync`), wrapped in a `SystemTask`, recording watermark and stats on
`SourceSync.for(:notion_mirror)`.

1. `POST /search`, `page_size 100`, sorted `last_edited_time` descending, no query.
   Walk pages until a result's `last_edited_time` is older than
   `watermark - 5 minutes`. For each result: upsert the page or data source from the
   result body (search returns full objects). If a page's cached tree exists
   (`root_children_fetched_at` set) and the new `last_edited_time` is later than
   `tree_complete_at` (or the tree is incomplete), set `blocks_stale_at`. Typical
   cost: 1–3 requests.
2. Refresh stale trees: pages with `blocks_stale_at` set, most recently edited first,
   through `TreeFetcher` until the run's request budget (300 requests) is spent.
   Remaining pages stay flagged and are refreshed on their next read or next sweep.
3. Write the new watermark (= the newest `last_edited_time` seen, minus nothing; the
   5-minute overlap is applied at read time). `last_edited_time` is minute-resolution,
   so the overlap also covers same-minute edits.

On boot nothing special happens: if the scheduler was down, the next run walks the feed
back to the old watermark.

### Backfill — `stacks:notion:backfill`, one-off, resumable

Walks the entire search feed (every page and data source the integration can see) and
upserts each; then fetches every data source object and its database object. Progress
(`next_cursor`, phase) lives in `SourceSync.for(:notion_backfill).cursor` so a killed
run resumes. At 1 req/s the feed walk is minutes; the ~1,269 data source + database
fetches are about 45 minutes. Seed trees: `NOTION_SEED_PAGE_IDS` (env, comma-separated;
default the Stacksbot control-center page `329131fea2c780718aa8f222b25c76e8` and the
Datazone page `dc51296819394138869baaefd534816a`) get a full tree fetch. Everything
else fills on first read.

### Reconcile — `stacks:notion:reconcile`, weekly

Full feed walk; any cached page or data source not seen and not `in_trash` is marked
`access_lost`. The nightly `stacks:sync_notion` keeps reconciling the two Stacks-owned
databases (Leads, Human Operating Manuals) with soft deletes, since TaskBuilder depends
on rows disappearing.

### Webhook — phase 3

`POST /api/notion/webhook` (no API key; HMAC instead). The first delivery after the
subscription is created carries `verification_token`; the controller logs it at
`warn` and the operator stores it in credentials as `notion.webhook_verification_token`.
Thereafter every delivery must satisfy `X-Notion-Signature ==
"sha256=" + HMAC-SHA256(raw_body, token)`; failures are 401. Events:

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

`Stacks::Etl::Notion::Connector < Stacks::Etl::Connector`, `source: :notion`
(`Document.source` enum gains `notion: 3`). `extract` yields every page with
`tree_complete_at` set whose `notion_last_edited_at` is newer than the document's
last projection: `external_id = notion_id`, `title`, `url`, `occurred_at =
notion_last_edited_at`, `content_hash = sha256(markdown)`, segments = markdown split
on blank lines, no contacts. Runs from `stacks:etl:sync_all` on the ETL dyno, which
already carries the embedding model. Database rows without cached trees are not
projected; they are structured data served by the query route. Exclusion policy:
`not_excluded` for everything (content shared with the integration is org content;
human overrides in ActiveAdmin still apply).

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
- Tree fetch budget exhausted (MCP `notion-fetch`): partial markdown + `truncated: true`;
  the next call resumes.
- Advisory lock held (overlapping scheduler runs): the second run exits with a log line.

## Rate-limit budget

At 1 req/s per process: the sweep spends 1–3 requests on the feed and up to 300 on stale
trees per 10-minute run (≤ 5 minutes of wall time). Web processes spend only on misses,
stale levels, filtered queries, searches, and writes. The 3/s connection budget is
respected by construction; the workspace budget is shared with stacksbot's writes and
sync and with Notion's own MCP, which this design cannot govern.

## Testing

**Unit / integration (mocha-stubbed HTTP, `Stacks::GhostTest` pattern):**

- Client: pacer spaces requests; 429 sleeps `Retry-After` then retries; cap honoured;
  `RateLimited` raised after `max_retries`; 5xx retried for GET only; version header.
- Mirror: upsert from a page object sets `database_id`, `data_source_id`,
  `notion_last_edited_at`, `page_title`; a second upsert with an older
  `last_edited_time` never moves the row backwards.
- Level cache: fresh level served without a request; stale level refetched and rows
  replaced; `tree_complete_at` set when the last level lands; `blocks_stale_at` cleared.
- Query route: unfiltered query served from cache with correct envelope, cursor, and
  `page_size`; filtered query passes through and upserts.
- Proxy: 403 without key; `X-Stacks-Cache` header per state; Notion 4xx passed through
  with status and body; writes invalidate.
- Sweep: overlap catches an edit at the watermark boundary; a page edited after its tree
  was cached becomes stale; budget stops tree refresh; watermark advances only on
  success.
- Renderer: fixture trees to golden markdown.
- MCP tools: `notion-fetch` truncation and resume; `notion-query-data-sources` equals
  the REST route.
- Existing tests for Lead, Human Operating Manual, TaskBuilder discoveries, and
  `ExploreOkrTool` pass unchanged after the scope switch.

**Live parity (required by the user):** `test/live/notion_parity_test.rb`, skipped
unless `NOTION_LIVE=1`, plus `rake stacks:notion:verify_parity` for ad-hoc runs. Using
the real dev token against api.notion.com with `Notion-Version: 2026-03-11`, for each
of: a Human Operating Manual page (`3bf131fea2c7809287f3c668e91d5332`), its block
children, the Leads database (`4d9b46b8bad542509f144347db37964d`) and data source
(`8ac2bac5-bc47-4674-851e-d1b1e4f779f2`), a filtered Tasks query, and a search —

1. call Notion directly and call the proxy on a cold cache; assert the JSON bodies are
   equal ignoring `request_id`;
2. call the proxy again (warm); assert the body equals the cold body and
   `X-Stacks-Cache: hit`;
3. for the block-children route, assert the cached level equals Notion's level for every
   cursor page.

The parity run's output is attached to the PR. It is also run once against the Heroku
app after deploy, before stacksbot is switched.

## Rollout

1. **Client + schema** — upgrade `Stacks::Notion`, migrations, scope switch, delete
   dead code, `sync_notion` on the new upsert with soft deletes. Full suite green.
2. **Mirror + reads** — `Mirror`, `TreeFetcher`, proxy controller, MCP tools,
   renderer, `Sweep`, `Backfill`, rake tasks, live parity test. Deploy; add the
   Scheduler job (`stacks:notion:sweep`, every 10 minutes); run backfill; run parity
   against prod; switch stacksbot's read paths.
3. **Freshness + corpus** — webhook endpoint and subscription, `reconcile`, ETL
   connector in `sync_all`.

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

- Confirm `Rack::Timeout`'s service timeout on the Heroku app (the in-request tree
  budget is set at 10 s to sit under a 15 s default).
- Confirm the exact list envelope keys for `POST /data_sources/:id/query` under
  `2026-03-11` in the parity test before hard-coding the cached-query envelope.
- The webhook subscription is created by hand in Notion's integration settings against
  the production URL; the verification token must be captured from the first delivery.
