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

> **Must deploy via `db:migrate`, not `db:schema:load`.** Two things are deliberately
> kept OUT of `db/schema.rb` so that `schema:load` works on a Postgres without pgvector
> (e.g. Heroku CI's in-dyno Postgres): (1) the `chunks.content_tsv` generated tsvector
> column + GIN index, and (2) the `vector` extension and the `embeddings.embedding`
> `vector(1024)` column + its HNSW index. The migrations create both in dev/prod; a
> `schema:load`-built DB is missing them and the MCP search tool would raise
> `PG::UndefinedColumn`/`extension not available`. `db:setup` re-establishes them via
> `db/seeds.rb` (and the test suite via `test_helper.rb`, which also skips the
> vector-dependent tests when pgvector is absent), but the canonical path is always to
> run the migrations.

The MCP endpoint is served by the existing web dyno (mounted at `/api/mcp`); no new
process type is required, so the `Procfile` is unchanged. The Streamable-HTTP
transport runs **stateless**, so it's safe across multiple web dynos.

## Web dyno sizing (for semantic/hybrid MCP search)

`search` with `mode: semantic|hybrid` embeds the **query** at request time using the
local model **on the web dyno** serving `/api/mcp`. So that dyno needs enough RAM for
the quantized model (~340 MB). Use a **Standard-2X+ / Performance** web dyno. Keyword
search has no such cost.

The model's multi-second cold start (load + ONNX session init) is **preloaded at boot**
so it no longer lands on the first user query: `config/puma.rb`'s `on_worker_boot` warms
`Stacks::Etl::Embedder` in a background thread in each worker (native ONNX sessions don't
survive `fork`, so it's done per-worker post-fork, not once during preload). Warming is
best-effort — a failure is logged, not fatal — and the first request still works if it
races the warmup (it just waits on the in-flight build via a mutex rather than starting a
second one). On a cold slug both workers download the model concurrently once; baking the
model into the slug (see follow-ups) removes that.

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

> **Gemini notes included:** `backfill_meet_all` now sweeps "Notes by Gemini" Drive docs (Drive-only, `until_time: nil`) for the same historical window, immediately after the transcript sweep.

- Impersonates every active Workspace user (~65), error-isolated per user. If **every**
  user fails (e.g. broken auth) the SystemTask is marked errored, not green.
- Covers only the **older** window (up to ~7 days ago); the recent window is owned by the
  nightly Meet API sync below. This time-partition is how the two sources avoid ingesting
  the same meeting twice (no fragile cross-source merge).
- First model use downloads the quantized mxbai ONNX model (~hundreds of MB) to the
  ephemeral dyno.
- Watch progress: `heroku logs --tail --app <app>` and the ActiveAdmin **MCP → ETL →
  Source syncs** + **Meetings** pages, and **System Tasks** for the run record.

## 4. Nightly ongoing sync (Performance dyno)

Add a **Heroku Scheduler** job (Scheduler lets you pick the dyno size):

- **Command:** `bundle exec rake stacks:etl:sync_all`
- **Dyno size:** Performance-L (enough RAM for the embedding model; faster)
- **Frequency:** daily (overnight)

`stacks:etl:sync_all` is the nightly entry point across ALL sources. It now invokes `sync_meet_all` (Meet REST API transcripts, recent window) and then `sync_gemini_notes_all` (Gemini notes, Drive-only, `until_time: nil`, recent window — default 10 days). Future sources are added here so the Scheduler job never changes.

## 5. Operating notes

- **Reversible exclusion:** excluded meetings keep their full transcript (segments).
  In ActiveAdmin, a Document's **Exclude** / **Include & index** actions flip exclusion;
  "Include & index" chunks+embeds it from the stored segments immediately (no re-fetch).
- **People resolution:** Calendar attendee emails resolve meeting people to `Contacts`;
  speakers Calendar couldn't resolve land in the per-document **Mentions** queue.
- **Single-tenant:** one org, the app's own credentials. The `X-Api-Key` is the access
  boundary — treat it as a secret.

## Known follow-ups (not blocking)

- Cross-source duplicates are avoided two ways: **time-partitioning** (Drive = older window,
  API = recent, with a deliberate ~7–10 day overlap so no meeting falls in a gap) AND an
  explicit **existence-check dedup** — each source skips a meeting the other already ingested,
  matched on the shared Drive doc id (`Document.for_drive_doc`), while excluding its own row so
  re-scans still re-ingest corrected transcripts. So the boundary overlap no longer produces
  duplicates.
- Bake the embedding model into the slug (or a cache) to avoid re-downloading it on
  each one-off dyno run.

## Retroactive: split already-ingested combined Notes+Transcript docs

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
