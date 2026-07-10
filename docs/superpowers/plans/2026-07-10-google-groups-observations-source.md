# Google Groups Observations Source — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the Google Groups email corpus an *observed* source in stacksbot — salient threads become Notion Observations with an accurate Gmail backlink.

**Architecture:** Part A adds one field (`root_message_id`) to the stacks `get_document` MCP response so an observing agent can build the precise `rfc822msgid` backlink. Part B authors Notion rows in stacksbot (a `google-groups` Sources row + a disabled `Observe: Google Groups` Job) and one rubric line — no stacksbot code; the sync reconcilers materialize them.

**Tech Stack:** Ruby on Rails 6.1 (stacks MCP tools, Minitest); Notion (stacksbot Sources/Jobs DBs + `observe` skill) via the Notion MCP.

## Global Constraints

- `get_document` response for a `google_groups` doc MUST include `root_message_id == doc.external_id` and `source == "google_groups"`; for non-Groups docs `root_message_id` is omitted and `meeting_key`/`segments` are unchanged.
- Do NOT change `Document#url` (avoids a 39k-row backfill; agent builds the Gmail link from `root_message_id`). Do NOT expose `group_email` (`url` already carries the group).
- Source Key format: `stacks:groups:<root_message_id>`. Observation `Source` value: `Google Groups` (plain — no per-group tag).
- Backlink Source Ref: primary `https://mail.google.com/mail/#search/rfc822msgid:<URL-encoded root_message_id>`; secondary = the doc's `url`.
- Scope: all groups (no denylist); forward-only rolling **7-day** window on `occurred_at`; thread-grain.
- Notion rows authored **Draft/disabled** (Sources `Status: Draft`; Job Enable unchecked). Nothing activates until `observe` is enabled org-wide.
- Notion DB IDs: Sources `9090b15496114236ba7a641d660c6e8c`; Jobs `329131fea2c78015ba3eed7476974b9b`; Observations `390131fea2c7808bb216c38b46c3ba55`.

---

## Part A — stacks MCP change

### Task 1: `get_document` returns `root_message_id` (+ `source`) for Groups docs

**Files:**
- Modify: `app/services/mcp/get_document_tool.rb`
- Test: `test/services/mcp/get_document_tool_test.rb` (create if absent; else add to the existing MCP tool test)

**Interfaces:**
- Produces: `get_document(id)` response now includes `source:` always, and `root_message_id:` for `google_groups` docs (= `Document#external_id`).

- [ ] **Step 1: Write the failing test**

```ruby
# test/services/mcp/get_document_tool_test.rb
require 'test_helper'

class Mcp::GetDocumentToolTest < ActiveSupport::TestCase
  test 'google_groups doc exposes root_message_id and source; meet doc does not expose root_message_id' do
    gg = Document.create!(source: :google_groups, external_id: '<root@x>',
                          excluded: :not_excluded, excluded_reason: :none,
                          url: 'https://groups.google.com/a/sanctuary.computer/g/dev', title: 'T')
    gg.chunks.create!(source: :google_groups, position: 0, content: 'hello')
    res = Mcp::GetDocumentTool.call(id: gg.id, server_context: nil)
    payload = res[:content] ? JSON.parse(res[:content].first[:text], symbolize_names: true) : res
    assert_equal '<root@x>', payload[:root_message_id]
    assert_equal 'google_groups', payload[:source]
    assert_equal [], payload[:segments]

    m = Meeting.create!(meet_source: :meet_api, meet_conference_record_id: 'cr/z')
    md = Document.create!(source: :meet, external_id: 'cr/z', source_record: m,
                          excluded: :not_excluded, excluded_reason: :none, title: 'M')
    md.chunks.create!(source: :meet, position: 0, content: 'hi')
    mres = Mcp::GetDocumentTool.call(id: md.id, server_context: nil)
    mpayload = mres[:content] ? JSON.parse(mres[:content].first[:text], symbolize_names: true) : mres
    assert_nil mpayload[:root_message_id]
    assert_equal 'meet', mpayload[:source]
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bin/rails test test/services/mcp/get_document_tool_test.rb`
Expected: FAIL — `root_message_id`/`source` missing from the payload.
(If `Responses.ok` shape differs, adjust how `payload` is extracted — inspect one real `Mcp::GetDocumentTool.call` return first and match it; keep the assertions.)

- [ ] **Step 3: Implement**

In `app/services/mcp/get_document_tool.rb`, replace the final `Responses.ok({...})` with:

```ruby
      extra = doc.google_groups? ? { root_message_id: doc.external_id } : {}
      Responses.ok({ id: doc.id, title: doc.title, url: doc.url, occurred_at: doc.occurred_at,
                     source: doc.source, meeting_key: meeting_key, segments: segments, body: body }
                   .merge(extra))
```

- [ ] **Step 4: Run to verify it passes**

Run: `bin/rails test test/services/mcp/get_document_tool_test.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/services/mcp/get_document_tool.rb test/services/mcp/get_document_tool_test.rb
git commit -m "feat(mcp): get_document returns source + root_message_id (for Groups backlinks)"
```

### Task 1b: Ship Part A

- [ ] Run the MCP tool suite: `bin/rails test test/services/mcp/` — expect green.
- [ ] Push branch `groups-observations-source`, open PR to `main`, merge, deploy (`git push production main`), verify the release SHA. (No migration.)
- [ ] Smoke: `heroku run rails runner "puts Mcp::GetDocumentTool.call(id: Document.google_groups.first.id, server_context: nil).inspect" --app g3d-stacks` → response includes `root_message_id`.

---

## Part B — stacksbot / Notion authoring (via Notion MCP)

> These tasks author Notion rows/skill text; "verification" replaces unit tests. Fetch each DB's schema first (`notion-fetch` on the DB id) so property names/types are exact before writing.

### Task 2: Sources DB row — `Google Groups`

**Files:** none (Notion). Target DB `9090b15496114236ba7a641d660c6e8c`.

- [ ] **Step 1:** `notion-fetch` the Sources DB (`9090b15496114236ba7a641d660c6e8c`) to read its property schema and open an existing row (e.g. Twist) to copy the exact property names + `## Fetch`/`## Source Key`/`## Source Ref`/`## Search`/`## Cite` body structure.

- [ ] **Step 2:** Create a new page in the Sources DB with properties: `Name = "Google Groups"`, `Slug = "google-groups"`, `Backing Tool = "stacks MCP"`, `Cite Label = "Google Groups"`, `Status = "Draft"` (match the real property names/types from Step 1). Body = the contract verbatim from the spec §B1 (Fetch, Source Key `stacks:groups:<root_message_id>`, the two Source Ref links, Search/Cite stubs).

- [ ] **Step 3 (verify):** `notion-fetch` the new row; confirm properties + body render, and that the body headings match the level the `sources-reconciler` expects (from the Twist row you copied). Confirm `Status = Draft` (won't materialize into the always-loaded `sources` skill until `Active`).

### Task 3: Jobs DB row — `Observe: Google Groups` (disabled)

**Files:** none (Notion). Target DB `329131fea2c78015ba3eed7476974b9b`.

- [ ] **Step 1:** `notion-fetch` the Jobs DB and an existing "Observe: …" job (or the Twist observe job) to copy property names (`Name`, `Cron`, `Deliver To`, the Enable/Active checkbox) and the body template.

- [ ] **Step 2:** Create a new Job page: `Name = "Observe: Google Groups"`, `Cron = "0 6 * * *"`, `Deliver To = "none"`, Enable/Active **unchecked**. Body = spec §B2 (load `observe`, run for `google-groups`, Output → Observations DB, Deliver To none).

- [ ] **Step 3 (verify):** `notion-fetch` the job; confirm it is **disabled** (so the cron reconciler will not schedule it) and the source slug in the body is `google-groups`.

### Task 4: Rubric tuning in the `observe` skill

**Files:** none (Notion). The `observe` skill lives in the stacksbot Skills DB (materialized to `workspace/skills/observe/SKILL.md`).

- [ ] **Step 1:** Locate the `observe` skill in Notion (search the Skills DB for "observe"). Read its Salience rubric section.

- [ ] **Step 2:** Add two lines to the rubric (do not restructure): (a) "Automated/transactional/notification mail (Sentry, CI/deploy, QuickBooks, Mailchimp, calendar invites, `no-reply@`) is LOW salience — reject fast unless it carries a real decision/risk/ask." (b) "Inbound inquiries on `hello@`/`info@`-style lists are lead signals worth recording." Keep them source-agnostic (they help all sources, not just Groups).

- [ ] **Step 3 (verify):** `notion-fetch` the skill page; confirm the two lines are present and the rest of the rubric is intact.

### Task 5: Document the go-live steps

**Files:**
- Modify (stacks repo): append a short "Observations" note to `docs/meet-etl-deploy.md` OR create `docs/google-groups-observations-golive.md`.

- [ ] **Step 1:** Write the manual go-live checklist (not automated — the `observe` machinery is disabled by design): (1) flip the `google-groups` Sources row `Status → Active` (materializes it into the `sources` skill); (2) enable the `observe` skill + the `Observe: Google Groups` Job when ready; (3) run once manually, confirm rows land in the Observations DB with `Source = Google Groups`, `Source Key stacks:groups:<root>`, working Gmail backlink; (4) re-run → zero new rows (idempotence); (5) confirm a Sentry/QuickBooks thread is rejected.

- [ ] **Step 2: Commit**

```bash
git add docs/
git commit -m "docs(groups): Google Groups observations source go-live checklist"
```

---

## Self-Review

**Spec coverage:** Part A field addition → Task 1; deploy → Task 1b; Sources row → Task 2; Observe Job → Task 3; rubric tuning → Task 4; activation/go-live → Task 5; out-of-scope items (historical backfill, last-activity window, per-message grain, sender attribution, Recall) are explicitly deferred in the spec and not tasked. No gaps.

**Placeholder scan:** none — Task 1 carries full code; Notion tasks carry the exact properties/body from the spec and a "fetch schema first" step so names are exact. The only intentional runtime-derived value is `payload` extraction in the test (Step 2 tells the implementer to match the real `Responses.ok` shape).

**Type/name consistency:** `root_message_id` (= `Document#external_id`), `source`, Source Key `stacks:groups:<root_message_id>`, `Source = Google Groups`, DB ids — all identical across spec and every task.

**Scope check:** two subsystems (stacks code, Notion authoring) but one coherent, small feature; fine for one plan executed A→B (B depends on A being deployed so the backlink field is live before the source is enabled).
