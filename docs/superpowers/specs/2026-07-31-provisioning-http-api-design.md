# Provisioning HTTP API — Design (generic, Forecast-hidden)

**Date:** 2026-07-31 (revised after PR #158 review)
**Status:** Approved direction (autonomous build; reworks the branch in place)
**Scope:** Phase 1 = HTTP API. Phase 2 (later) = MCP tools wrapping the same code.

## Problem

An agent should stand up a project end-to-end from a one-line instruction, e.g. *"Ensure the
Qualitate project has a $450p/h tracker, and set up a weekly recurring assignment for
hugh@sanctuary.computer."* Today none of this is programmable, and — critically — **the API must
NOT expose Forecast concepts.** Forecast may be swapped for a different hour-tracking tool (or an
in-house one), so the surface speaks generic Stacks-native terms; Forecast is a hidden
implementation detail translated behind the controllers.

## Vocabulary (API surface — Forecast never appears)

| API concept | Identity exposed | Internally (hidden) |
|---|---|---|
| **Contributor** (a person) | `contributor.id` (native) | `Contributor` → `forecast_person_id` (= ForecastPerson `forecast_id`) |
| **Client** (a customer) | referenced by **name** | `ForecastClient` (find-or-create by name) |
| **Project Tracker** (an engagement) | `project_tracker.id` (native) | `ProjectTracker` (native model; no client column — derived) |
| **Workstream** (a rate-bearing schedulable strip in a tracker) | `ProjectTrackerForecastProject.id` (native join id) | a `ForecastProject` under the tracker's client, attached via the join; carries the rate tag(s) |
| **Rate** | a number (e.g. `450`) | a `"450p/h"` tag on the workstream's ForecastProject (multiple allowed) |
| **Recurring Assignment** | `recurring_assignment.id` | `RecurringAssignment` (keeps `forecast_person_id`/`forecast_project_id` internally) |

**Why "workstream" (not "role"):** `role` is already overloaded 4 ways — Runn's global rate-card
job title (orthogonal to projects), Stacks project-lead types, `ForecastPerson.roles` studio tags,
and `UnresolvableRole`/`roleId` in the adjacent projection write-path. "Workstream" collides with
none.

## Principles

- **Forecast is hidden.** No `forecast_*` in any route, param, or response. Controllers translate
  generic ids → Forecast ids at a thin seam, following the existing precedent
  (`Api::V1::ProjectedAssignmentsController` speaks `contributor_id`/`project_tracker_id`;
  `Resourcing::RunnPersonResolver` is the documented "swap Runn here" seam).
- **Internal models unchanged.** `RecurringAssignment` still stores Forecast ids; genericization is
  purely a surface remap (`contributor.id → contributor.forecast_person_id`, trivially the same
  value; `workstream_id → join.forecast_project_id`). No model/column renames in phase 1.
- **Pure CRUD; agent orchestrates.** Endpoints are thin creates/reads; "ensure/find-or-create"
  lives in the calling agent (read-then-create). The one exception is **client find-or-create**,
  which happens under the hood on first-workstream (below).
- **Multiple rates per workstream.** Rate ops add/remove ONE `…p/h` tag, never clobber others.
- **Immediate local consistency.** Every Forecast write upserts the local mirror in-request.
- **Auth:** `X-Api-Key` via the existing `ApiController#check_private_api_key!` (403 on failure).

## Error handling (fix, not reinvent)

`ApiController` already has global handling via `HandlesExceptions#handle_for_json`
(`rescue_from ::StandardError`): `RecordInvalid`→422-with-details, `ParameterMissing`→422. **Remove
all bespoke controller `rescue`/`render_error` blocks** and let exceptions propagate.

**Latent bug to fix:** the handler's `else` branch references `Stacks::Errors::Unexpected`, which is
**not defined anywhere** (confirmed at boot) — so any genuinely-unexpected error in any API
controller currently raises `NameError` inside the handler. Define it in `lib/stacks/errors.rb`:

```ruby
class Unexpected < Stacks::Errors::Base
  def initialize(detail, exception = nil)
    @detail = detail
    Sentry.capture_exception(exception) if exception && defined?(Sentry)
    Rails.logger.warn("[Stacks::Errors::Unexpected] #{exception&.class}: #{exception&.message}")
  end
  def title; 'Unexpected Error'; end
  def detail; @detail; end            # generic — never echoes the underlying exception message
  def source; nil; end
  def status; :internal_server_error; end
end
```

This resolves the info-leak finding globally (a failed Forecast write → generic 500, logged/Sentry,
no upstream body leaked) AND fixes a pre-existing app-wide bug.

## Client find-or-create (the one bit of server-side "ensure")

A ProjectTracker is conceptually one client, derived from its workstreams'
ForecastProject → `forecast_client`. So:

- On **first** workstream: resolve the client by name from the local mirror; if absent, create it in
  Forecast (`create_client`) + mirror. Then create the workstream's ForecastProject under it.
- On **subsequent** workstreams: use the tracker's existing client (from any current workstream);
  the `client` param is optional and, if given, should match (else a warning). The tracker never
  stores a `client_id` — no migration, no new invariant.

## Forecast client additions (`lib/stacks/forecast.rb`)

Already have: `create_project`, `update_project`, `add_project_rate!`, `remove_project_rate!`,
`rate_tag`, mirror upsert. **Add:**
- `create_client(name:)` → `POST /clients` (`{ client: { name: } }`) + upsert local `ForecastClient`
  mirror (mapping per `sync_clients!`). Returns the parsed client.
- `find_or_create_client!(name)` (can live in the provisioning seam) → local `ForecastClient` by
  case-insensitive name, else `create_client`.

## HTTP Endpoints (all `/api`, `X-Api-Key`)

### Reads (resolvers)
- `GET /api/contributors?email=` → `[{ id, email, name }]` (Contributor native id; email via
  `forecast_person`, joined — case-insensitive).
- `GET /api/project_trackers?client=<name>` (and `?name=<tracker name>`) → `[{ id, name, client,
  workstreams: [{ id, name, code, rates: [..] }] }]`. Lets the agent check what exists.

### Writes
- `POST /api/project_trackers` — `{ name, msa_url?, sow_url?, budget_low_end?, budget_high_end? }`
  → `{ id, name, warnings }`. Creates the tracker + MSA/SOW links (passed in, or placeholder +
  warning when omitted). No client, no workstreams yet.
- `POST /api/project_trackers/:id/workstreams` — `{ name, code, rate?, client? }`
  → `{ id, name, code, rates, client, project_tracker_id }`. Resolves the tracker's client
  (existing) or find-or-creates by `client` name (first workstream); creates a ForecastProject
  under that client with `code` + the rate tag(s); attaches it via the join; returns the **join
  row id** as the workstream `id`.
- `POST /api/project_trackers/:tracker_id/workstreams/:id/rates` — `{ rate }` → add rate.
  `DELETE …/workstreams/:id/rates?rate=450` → remove rate. Returns the workstream with `rates`.
  (Rate on the request body/query — never a path segment — so decimals like `99.75` are safe.)
- `POST /api/recurring_assignments` — `{ contributor_id, workstream_id, allocation_hours?,
  weekdays?, starts_on, ends_on? }`. Translates `contributor_id → contributor.forecast_person_id`
  and `workstream_id → join.forecast_project_id`, creates the `RecurringAssignment`. Defaults:
  8h/day, Mon–Fri, start today. Returns `{ id, contributor_id, workstream_id, allocation_hours,
  weekdays, starts_on, ends_on }` (no forecast ids in the response).

## The composed one-liner (agent-side)

1. `GET /api/contributors?email=hugh@…` → contributor id.
2. `GET /api/project_trackers?client=Qualitate` → existing tracker? If none, `POST
   /api/project_trackers { name: "Qualitate", … }` (placeholder MSA/SOW + warning).
3. Does a workstream already carry rate 450? If not, `POST …/:id/workstreams { name, code, rate:
   450, client: "Qualitate" }` (find-or-creates the Qualitate client under the hood).
4. `POST /api/recurring_assignments { contributor_id, workstream_id, allocation_hours: 8 }`
   (weekdays default Mon–Fri).

## Errors & safety

- Forecast writes happen **outside** the DB transaction; local mirror/link/join writes inside one.
- All error rendering via the global handler (generic 500 for unexpected/upstream failures, 422 for
  validation) — no per-controller rescues, no leaked upstream bodies.

## Testing (Minitest + Mocha)

- `Stacks::Forecast#create_client` (+ mirror); the seam's `find_or_create_client!`.
- Workstream create: first (find-or-creates client, creates project+join, sets rate) and subsequent
  (reuses tracker's client); returns join id; rejects a code-less project via the tracker's existing
  validations.
- Recurring assignment: `contributor_id`/`workstream_id` translate correctly; defaults; response has
  no forecast ids.
- Resolvers: contributor by email; trackers by client name with nested workstreams+rates.
- Error handling: define-and-render `Unexpected` (generic body, 500); a forced upstream failure
  returns a generic message, not the Forecast body; RecordInvalid → 422 with details.
- Auth 403 on every endpoint.

## Out of scope (phase 2)
- MCP tools — thin wrappers over the same controllers/seam.

## Flagged decisions (for PR review)
1. **Forecast fully hidden**; generic surface (contributors/project_trackers/workstreams/rates/
   recurring_assignments); translation at a thin seam, internal models keep Forecast ids.
2. **"workstream"** for the rate strip (identity = native join id).
3. **Client find-or-create on first workstream**; tracker stays client-less (derived), no migration.
4. **Rates add/remove, multi-rate-safe**; rate off the path (decimal-safe).
5. **MSA/SOW passed in; placeholder + warning fallback** when omitted.
6. **Recurring defaults:** 8h/day, Mon–Fri, today.
7. **Error handling via the global `HandlesExceptions`** + a newly-defined `Stacks::Errors::Unexpected`
   (fixes a latent app-wide `NameError`); no per-controller rescues.
