# Human Operating Manual Tasks — Design

**Date:** 2026-08-17
**Status:** Approved

## Goal

Every active admin user should have a Human Operating Manual page in Notion
(the "🤼 Human Operating Manuals" database) with a PDF attached under its
"Pigment.is Superpowers PDF" property. When either is missing, the person
should see a task on their Stacks tasks dashboard, exactly like existing
task detection (e.g. `:missing_skill_tree`).

Two new task types:

- `:missing_human_operating_manual` — no manual page in Notion matches the
  admin user's email.
- `:missing_superpowers_pdf` — a manual page exists, but its
  "Pigment.is Superpowers PDF" file property is empty.

Both tasks are owned by the admin user themselves.

## Notion source

- Database: 🤼 Human Operating Manuals, ID `5d59dcd95bfb458a9747ce7d6ce9e009`
  (data source `60e5531e-4b73-4431-91a6-e4ea54eef4b4`).
- Relevant properties: `Email` (email), `Pigment.is Superpowers PDF` (file),
  `Inactive` (checkbox), `Name` (title), `Who` (person).
- Join key: manual `Email` property ↔ `AdminUser.email`, case-insensitive.

## Architecture

Follows the existing `Stacks::Notion::Lead` + `Discoveries::NotionLeads`
pattern end-to-end.

### 1. Sync

Add to `Stacks::Notion::DATABASE_IDS` (`lib/stacks/notion.rb`):

```ruby
HUMAN_OPERATING_MANUALS: "5d59dcd95bfb458a9747ce7d6ce9e009"
```

The daily rake task (`lib/tasks/stacks.rake` ~line 402) syncs every entry in
`DATABASE_IDS` into `NotionPage` records. No scheduler changes needed.

### 2. Wrapper — `Stacks::Notion::HumanOperatingManual`

New file `lib/stacks/notion/human_operating_manual.rb`, subclass of
`Stacks::Notion::Base` (mirrors `Stacks::Notion::Lead`):

- `self.all` — wraps `NotionPage.human_operating_manual`
- `email` — the "Email" property value (String or nil)
- `superpowers_pdf?` — true when the "Pigment.is Superpowers PDF" file
  property contains at least one file
- `notion_link` — external URL to the Notion page
- `page_title` — delegates to the underlying `NotionPage`
- `notion_page` — the underlying record (needed by TaskBuilder hydration)

`NotionPage` gains a `.human_operating_manual` scope and an
`#as_human_operating_manual` instance method (mirrors `.lead` / `#as_lead`),
both keyed on the dashified database ID.

### 3. Discovery — `Discoveries::HumanOperatingManuals`

New file `lib/stacks/task_builder/discoveries/human_operating_manuals.rb`,
registered in `Stacks::TaskBuilder::DISCOVERY_CLASSES` and required at the
top of `lib/stacks/task_builder.rb`.

Algorithm:

1. Load all manuals once via the wrapper; group by downcased `email`.
   Manuals with a blank email are ignored.
2. For each `AdminUser.not_ignored` where `user.active?`:
   - No manual matches → `task(subject: user, type:
     :missing_human_operating_manual, owners: [user])`
   - Matches exist but none has a PDF → `task(subject: manual, type:
     :missing_superpowers_pdf, owners: [user])` where `manual` is the first
     match in ascending `NotionPage.id` order (deterministic across cache
     rebuilds).
   - Any matching manual has a PDF → no task.

Rules:

- Multiple manuals matching one email: resolved if any match; PDF-satisfied
  if **any** matching manual has a PDF. Never emit both task types for one
  user.
- A manual flagged `Inactive` in Notion still counts as that person's
  manual — an active admin should never be asked to create a second page.

### 4. Display plumbing

`app/models/stacks_task.rb`:

- `HUMANIZED_TYPES`:
  - `missing_human_operating_manual: "Admin user needs a Human Operating Manual"`
  - `missing_superpowers_pdf: "Human Operating Manual needs a Pigment.is Superpowers PDF"`
- `subject_class_key`: `Stacks::Notion::HumanOperatingManual` →
  `"human_operating_manuals"`
- `subject_display_name`: page title, falling back to the manual's email
- `subject_url`: the manual's `notion_link`; `subject_url_external?` → true

`lib/stacks/task_builder.rb`:

- `subject_id_for`: `Stacks::Notion::HumanOperatingManual` → underlying
  `notion_page.id`
- `batch_load_subjects`: load `NotionPage.where(id: ids)` and re-wrap via
  `as_human_operating_manual` (same shape as the `Stacks::Notion::Lead`
  branch)

## Error handling

- Notion API failures leave local `NotionPage` data stale; discovery reads
  only local data, so the dashboard keeps working.
- Discovery exceptions are already isolated per-discovery by the
  `rescue` in `TaskBuilder#build_tasks` (logged + Sentry, other discoveries
  unaffected).

## Testing

`test/lib/stacks/task_builder/discoveries/human_operating_manuals_test.rb`,
mirroring `notion_leads_test.rb` (stub the `NotionPage` scope with in-memory
pages; create real `AdminUser` records):

- Active admin with no matching manual → `:missing_human_operating_manual`
  owned by them, subject is the AdminUser.
- Active admin whose manual has no PDF → `:missing_superpowers_pdf` owned by
  them, subject is the manual (external Notion URL).
- Active admin whose manual has a PDF → no tasks.
- Email matching is case-insensitive.
- Ignored (`ignore: true`) and inactive admins are skipped.
- Multiple manuals for one email: PDF on any match suppresses the PDF task;
  never both task types for one user.
- Both new types have explicit `HUMANIZED_TYPES` labels.

Wrapper property extraction (email, PDF presence) is exercised through the
discovery tests via Notion-shaped `data` hashes, matching how Lead behavior
is covered.

## Out of scope

- No changes to `ProjectTrackerLink.operator_manual` (per-project manuals —
  unrelated).
- No on-demand re-check button; the existing 24h task cache and
  `BustsTaskCache` behavior apply as-is.
- No enforcement for admins without Stacks accounts or non-admin
  contributors.
