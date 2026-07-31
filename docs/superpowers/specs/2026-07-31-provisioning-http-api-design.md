# Provisioning HTTP API — Design

**Date:** 2026-07-31
**Status:** Approved direction (autonomous build; flagged decisions surfaced at PR review)
**Scope:** Phase 1 = HTTP API. Phase 2 (separate PR) = MCP tools wrapping the same code.

## Problem

We want an agent to stand up a project end-to-end from a one-line instruction, e.g.
*"Ensure the Qualitate project has a $450p/h forecast project tracker, and set up a weekly
recurring assignment for hugh@sanctuary.computer on it."* Today none of this is programmable:
ProjectTrackers are ActiveAdmin-only, Forecast projects/clients are read-only in Stacks, and
rates live as Forecast tags with no write path.

The existing MCP **write** server is deliberately scoped to the projection plane ("rates and
money have no tools, so no composition can reach them"). Provisioning crosses that boundary, so
rather than erode it we give provisioning its **own HTTP API surface**. MCP tools (phase 2) will
wrap the same service methods.

## Principles

- **Pure CRUD.** Endpoints are thin resource creates/reads. The "ensure / find-or-create"
  intelligence lives in the *calling agent* (read-then-create), not in clever server logic.
- **Multiple rates per project are normal.** Rate operations *add/remove* a single `…p/h` tag and
  never clobber the others. A project may carry `["450p/h", "300p/h"]`.
- **Immediate local consistency.** Any Forecast write reflects into the local mirror
  (`ForecastProject`) in the same request, so a subsequent read is correct without waiting for the
  ~10-minute `sync_all!`.
- **Same auth as the MCP surface.** `X-Api-Key` checked against `config[:stacks][:private_api_key]`
  (constant-time), via the existing `ApiController#check_private_api_key!`.

## Architecture

```
Api::* controllers (thin, X-Api-Key)          ← phase 1 (this PR)
        │  call
        ▼
Stacks::Forecast (new write methods + mirror)  +  models (ProjectTracker, RecurringAssignment, …)
        ▲  call
Mcp::* provisioning tools                       ← phase 2 (next PR), same code
```

Controllers live under the existing `namespace :api` (`config/routes.rb:16`) and inherit
`ApiController`, adding `before_action :check_private_api_key!`. No new base infra.

## Forecast client additions (`lib/stacks/forecast.rb`)

Currently only `create_assignment`/`delete_assignment` exist. Add (same `write_headers` +
`{ resource: {...} }` envelope pattern, verified live):

- `create_project(client_id:, name:, code:, tags: [], notes: "")` → `POST /projects`, returns the
  parsed `"project"`. Then `upsert_project_locally!` (below).
- `update_project(forecast_id, attrs)` → `PUT /projects/:id` (partial), returns parsed `"project"`.
  Then `upsert_project_locally!`.
- `upsert_project_locally!(api_project)` (private) — maps the API project hash into a local
  `ForecastProject` row and `upsert_all(unique_by: :forecast_id)`, mirroring the column mapping in
  `sync_projects!` (`forecast_id`, `name`, `code`, `notes`, `start_date`, `end_date`, `harvest_id`,
  `archived`, `client_id`, `tags`, `updated_at`, `updated_by_id`, `data`). This is what makes the
  new project/rate readable immediately.

Clients are **not** creatable in phase 1 — the flow assumes the Forecast client (e.g. "Qualitate")
already exists (resolvable by name). (Flagged: no create-client.)

## Rates (Forecast tags — supports multiples)

- Normalize a numeric rate to a bare tag: `450 → "450p/h"`, `99.75 → "99.75p/h"` (strip a trailing
  `.0`; no `$`). A `"$450p/h"` input is coerced to `"450p/h"`.
- **Add rate:** read the project's current `tags`, append the normalized tag iff absent, `PUT` the
  full tags array, reflect locally. Idempotent; never removes other rates.
- **Remove rate:** filter the tag out, `PUT`, reflect locally.
- Rate presence/parse reuses the existing convention (`ForecastProject#hourly_rate` reads
  `tags` ending in `"p/h"`).

## HTTP Endpoints

All under `/api`, `X-Api-Key` required, JSON in/out. Errors return a JSON `{ "error": "…" }` body
with an appropriate 4xx (validation/not-found) or 401 (auth). Success returns the created/looked-up
resource(s) as JSON, including `forecast_id`s the agent needs for the next call.

### Reads (resolvers)

- `GET /api/forecast_clients?name=Qualitate` → matching clients `[{forecast_id, name}]`
  (case-insensitive, trimmed — mirrors the Runn action's name match).
- `GET /api/forecast_clients/:forecast_id/forecast_projects` → the client's projects, each with
  `{forecast_id, name, code, rates: [450.0, …], hourly_rate, project_tracker_id|null, archived}`.
- `GET /api/forecast_people?email=hugh@sanctuary.computer` → `[{forecast_id, email, name}]`.

### Writes (CRUD)

- `POST /api/forecast_projects`
  Body: `{ client_id, name, code, rates: [450], notes? }`. Creates a Forecast project under the
  client, tags = the rate tags, reflects locally. Requires `code` (needed for tracker attachment;
  the caller supplies it — see flagged decision on generation). Returns the project.
- `POST /api/forecast_projects/:forecast_id/rates`  Body: `{ rate: 450 }` → add rate.
  `DELETE /api/forecast_projects/:forecast_id/rates/:rate` → remove rate. Both return the updated
  project with its full `rates`.
- `POST /api/project_trackers`
  Body: `{ name, budget_low_end?, budget_high_end?, msa_url, sow_url, forecast_project_ids: [id,…] }`.
  Creates the tracker, builds an `msa` and a `sow` `ProjectTrackerLink` (names default "MSA"/"SOW",
  urls validated `http|https`), and attaches each forecast project via
  `project_tracker_forecast_projects` (join keyed on `forecast_id`). Enforces the model's existing
  validations (name present, MSA+SOW present, each attached project has a non-blank `code`, no code
  collision with another tracker). Returns the tracker with attached project ids + link ids.
  - `msa_url`/`sow_url` are accepted inputs (per decision). If **omitted**, fall back to a
    placeholder link (`https://TODO.example.com/msa`) and include a `"warnings": ["MSA link is a
    placeholder — replace it"]` array in the response, so the one-liner still succeeds but the gap
    is surfaced. (Flagged.)
- `POST /api/recurring_assignments`
  Body: `{ forecast_person_id, forecast_project_id, allocation_hours?, weekdays?, starts_on, ends_on? }`.
  Plain CRUD over the `RecurringAssignment` model shipped in PR #157. Defaults: `allocation_hours`
  → 8 (→ 28 800 s/day), `weekdays` → `[1,2,3,4,5]` (Mon–Fri), `starts_on` → today if omitted.
  Returns the created rule.

## The composed "ensure" flow (done by the agent, not the server)

1. `GET /api/forecast_clients?name=Qualitate` → client id.
2. `GET …/forecast_projects` → look for one whose `rates` include 450.
3. If none: `POST /api/forecast_projects` `{client_id, name, code, rates:[450]}`. If a project exists
   but lacks the rate: `POST …/:id/rates {rate:450}`.
4. `POST /api/project_trackers` `{name, msa_url, sow_url, forecast_project_ids:[fp]}`.
5. `GET /api/forecast_people?email=hugh@…` → person id;
   `POST /api/recurring_assignments {forecast_person_id, forecast_project_id, allocation_hours:8, weekdays:[1..5]}`.

## Errors & safety

- Non-2xx from Forecast → surface a clean `{error}` (log + Sentry internally), never leak bodies.
- Forecast writes happen **outside** the DB transaction; local mirror/link writes happen inside one
  (the "Create Runn Project" pattern), so a failed API call can't leave a dangling local row.
- Reuse `ApiController`'s `rescue_from StandardError` / `HandlesExceptions` for uniform error JSON.

## Testing (Minitest + Mocha; controller/integration tests)

- **`Stacks::Forecast` writes:** stub `Stacks::Forecast.post/put` (per the assignment write tests);
  assert path + `{project:{…}}` envelope + local upsert.
- **Rate add/remove:** starting tags `["300p/h"]`, add 450 → `["300p/h","450p/h"]` (idempotent on
  repeat); remove 450 → `["300p/h"]`.
- **Endpoints (request/integration tests):** auth (missing/wrong key → 401); create project; add
  rate; create tracker (with links + attachment; and the placeholder-warning path); create recurring
  assignment (defaults applied); resolvers. Stub the Forecast HTTP layer; assert on JSON + DB state.
- Follow existing `test/integration/mcp_write_endpoint_test.rb` for the auth/JSON-RPC-adjacent shape
  and `test/controllers`/`test/integration` conventions.

## Out of scope (phase 2, next PR)

- **MCP tools** — one thin `Mcp::*` wrapper per write endpoint, on a provisioning grouping, so the
  projection write-server stays pure. Same service methods, `{before:, after:}` envelope,
  `WriteValidation` + a guard.

## Flagged decisions (for PR review)

1. **HTTP-first; MCP tools deferred to phase 2** (per "start with HTTP").
2. **No create-client** — the Forecast client must already exist; we resolve it by name.
3. **`code` is a caller-supplied param** on project creation (required for tracker attach). If you'd
   rather auto-generate per a convention (e.g. `G3D-…`), say so — I didn't find an existing code
   generator.
4. **Rates are add/remove, multi-rate-safe** — never "set/replace all."
5. **MSA/SOW passed in; placeholder + warning fallback** when omitted (keeps the one-liner working
   while surfacing the gap).
6. **Recurring-assignment defaults:** 8h/day, Mon–Fri, start today when unspecified.
7. **Immediate local mirror upsert** on every Forecast write (no 10-min sync wait).
