# Notion mirror — deploy notes

Spec: `docs/superpowers/specs/2026-09-10-notion-mirror-design.md`.

## Env / config vars (Heroku)

| var | web dynos | scheduler commands |
| --- | --- | --- |
| `NOTION_RPS` | `0.6` | `1.2` (set inline on each command) |
| `NOTION_SEED_PAGE_IDS` | — | optional; default `329131fea2c780718aa8f222b25c76e8,dc51296819394138869baaefd534816a` |
| `NOTION_SWEEP_OVERLAP` | — | optional, seconds, default 300 |

Credentials (every host block): `notion.token` (existing), `stacks.private_api_key` (existing).

## Deploy order (phase 1 ships the migration)

1. `heroku run bin/rails db:migrate` **before** the release goes live (no `release:` phase in the Procfile).
   Verify the scope switch: `heroku run bin/rails runner 'puts NotionPage.lead.count, NotionPage.human_operating_manual.count'` should print roughly 1018 and 94 (the pre-migration Leads/HOM row counts); after the first `stacks:sync_notion` run, the same counts must not have dropped to 0 — if they did, `parent.database_id` is missing from the API objects and `Mirror.upsert_page` needs a fallback.
2. Push / release.
3. Scheduler: add `NOTION_RPS=1.2 bin/rails stacks:notion:sweep` every 10 minutes and `NOTION_RPS=1.2 bin/rails stacks:notion:reconcile` daily. `stacks:sync_notion` stays as it is.
4. One-off: `heroku run NOTION_RPS=1.2 bin/rails stacks:notion:backfill` — re-run until `SourceSync(notion_backfill).cursor.phase == "done"`.
   Legacy rows (the ~23.6k written by the pre-mirror sync, which stripped `icon`, `cover` and file payloads and left `page_fetched_at` nil) serve as **misses** until the backfill's feed walk rewrites them, which is why stacksbot's read switch (step 6) must wait for `phase == "done"`.
5. Parity against prod: `APP_BASE_URL=https://stacks.garden3d.net STACKS_API_KEY=… bin/rails stacks:notion:verify_parity` from a laptop with the dev token.
6. Switch stacksbot reads: `TOOLS.md` `## Notion` reads → `https://stacks.garden3d.net/api/notion/v1/...` with `X-Api-Key`; `notion-query-dump.mjs` / `ops-preread-dump.mjs` gain `NOTION_BASE_URL` + auth header. Writes stay on `ntn`.

## Behavioural notes (deviations from a pure mirror)

- Responses carry `X-Stacks-Cache: hit|stale|miss|live` and `X-Stacks-Fetched-At`.
- Cached bodies omit `request_id` (and `request_status`); live pass-throughs keep them.
- Notion file URLs expire ~1 h after fetch; a cached body may carry an expired one.
- Trashed pages and lost access are learned by the daily reconcile, not the sweep.
- Queries and searches are never served from cache.
- On a miss/stale, `GET blocks/:id/children` asks Notion for `page_size=100` and returns Notion's body, so the caller's `page_size` is honoured only on hits.
- Cursors differ by cache state: block ids on hits, Notion's opaque cursors on live fills. If a level flips to stale mid-pagination (a sweep set `blocks_stale_at`), the next cursor page returns a 400 — restart pagination from the first page.
- `stacks:notion:backfill` re-run after `phase == "done"` only re-walks the seed trees; to re-run the full feed, clear the `SourceSync` row for `notion_backfill` (`SourceSync.find_by(source: "notion_backfill")&.update!(cursor: {})`).
- The sweep skips pages marked `in_trash` or `access_lost`; a 403/404 during a tree refresh marks the page `access_lost` and clears its flags (stat `pages_access_lost`).
- First-ever sweep with no watermark walks only the 5 newest feed pages; the backfill owns history.
- Notion 5xx and 401 pass-throughs are reported to Sentry; other 4xx are not.

## Watching it

ActiveAdmin → Dashboard → ETL: Source syncs: `notion_mirror` (watermark + per-run stats: `requests_spent`, `trees_refreshed`, `pages_still_stale`), `notion_backfill` (phase). Request log lines: `[Stacks::Notion] GET /pages/… 200 412ms`.
