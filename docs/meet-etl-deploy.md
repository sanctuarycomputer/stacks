# Meet Transcript ETL + MCP — Deploy & Operate Runbook

How to deploy the org-wide Meet-transcript ingestion and run the overnight 90-day
backfill. Spec: `docs/superpowers/specs/2026-06-28-org-vector-store-and-etl-design.md`.

## 0. Prerequisites (one-time)

**Google (done):**
- Domain-wide delegation for service account client `101624115441833851120`
  (`stacks@stacks-305217.iam.gserviceaccount.com`) authorized for:
  `meetings.space.readonly`, `drive.readonly` (and the existing full `calendar` +
  directory scopes the app already uses).
- **Google Meet API** enabled in GCP project `stacks-305217`.

**Heroku Postgres — REQUIRED before deploy:**
- pgvector is only available on **Standard / Premium / Private / Shield** tiers
  (PG 15+, pgvector 0.8.x). Confirm the prod DB is on a supported tier — the
  `enable_extension "vector"` migration **will fail the deploy on Essential/Mini**.

**Bundler / native gem:**
- The local embedding model uses `onnxruntime`, which ships platform-specific native
  gems. `Gemfile.lock` now includes the `x86_64-linux` platform (run
  `bundle lock --add-platform x86_64-linux` if it's ever missing) so the Linux native
  gem installs on Heroku.

## 1. Deploy

```bash
git push heroku <branch>:main          # or your normal deploy flow
heroku run rake db:migrate --app <app> # creates the ETL tables + enables pgvector
```

The MCP endpoint is served by the existing web dyno (mounted at `/api/mcp`); no new
process type is required, so the `Procfile` is unchanged. The Streamable-HTTP
transport runs **stateless**, so it's safe across multiple web dynos.

## Web dyno sizing (for semantic/hybrid MCP search)

`search` with `mode: semantic|hybrid` embeds the **query** at request time using the
local model **on the web dyno** serving `/api/mcp`. So that dyno needs enough RAM for
the quantized model (~340 MB) and eats a one-time model load on the first semantic
query (slow first request, then cached for the dyno's life). Use a **Standard-2X+ /
Performance** web dyno, or preload the model at boot. Keyword search has no such cost.

## 2. Connect the agent to MCP

Point the agent (claude.ai / Claude Code) at:

- **URL:** `https://<app>/api/mcp`
- **Header:** `X-Api-Key: <value of credentials[<host>][:stacks][:private_api_key]>`

It exposes read-only tools: `search`, `get_document`, `list_documents`, `list_sources`.
Excluded meetings are never returned by any tool.

## 3. Overnight 90-day backfill (one-time, Drive sweep, all users)

The Meet REST API only retains ~30 days of conference records, so the 90-day backfill
reads transcript Docs from each user's Drive. Run it **detached** on a big dyno (the
local embedding model needs RAM and the run is long):

```bash
heroku run:detached --size=performance-l "rake 'stacks:etl:backfill_meet_all[90]'" --app <app>
```

- Impersonates every active Workspace user (~65), error-isolated per user.
- First model use downloads the quantized mxbai ONNX model (~hundreds of MB) to the
  ephemeral dyno.
- Watch progress: `heroku logs --tail --app <app>` and the ActiveAdmin **MCP → ETL →
  Source syncs** + **Meetings** pages, and **System Tasks** for the run record.

## 4. Nightly ongoing sync (Performance dyno)

Add a **Heroku Scheduler** job (Scheduler lets you pick the dyno size):

- **Command:** `bundle exec rake stacks:etl:sync_meet_all`
- **Dyno size:** Performance-L (enough RAM for the embedding model; faster)
- **Frequency:** daily (overnight)

This pulls the recent window (default last 7 days; `sync_meet_all[N]` to change) via the
richer Meet REST API for every user, embedding new transcripts locally.

## 5. Operating notes

- **Reversible exclusion:** excluded meetings keep their full transcript (segments).
  In ActiveAdmin, a Document's **Exclude** / **Include & index** actions flip exclusion;
  "Include & index" chunks+embeds it from the stored segments immediately (no re-fetch).
- **People resolution:** Calendar attendee emails resolve meeting people to `Contacts`;
  speakers Calendar couldn't resolve land in the per-document **Mentions** queue.
- **Single-tenant:** one org, the app's own credentials. The `X-Api-Key` is the access
  boundary — treat it as a secret.

## Known follow-ups (not blocking)

- Cross-source dedup: a meeting backfilled via Drive and later synced via the Meet API
  produces two documents (different external IDs). Unify later via the transcript's
  Drive doc id (the Meet API exposes it on the transcript).
- Semantic search materializes candidate chunk ids into an `IN (...)` list — fine now,
  revisit if the corpus grows very large.
- Bake the embedding model into the slug (or a cache) to avoid re-downloading it on
  each one-off dyno run.
