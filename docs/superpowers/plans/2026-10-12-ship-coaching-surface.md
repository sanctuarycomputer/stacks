# Ship coaching surface: review fixes plan

Spec: `docs/superpowers/specs/2026-10-12-ship-coaching-surface-design.md`. The first build is commit
`feat(weekly-ships): grade on the Last Ship pill…` on `feat/ship-coaching-surface` (PR #204). Two
adversarial reviews (code, and styled screenshots) found the items below. Each task is test-first:
add or change the test in `test/integration/admin_weekly_ship_coaching_test.rb`, see it fail, fix.

Run tests with `DATABASE_URL=postgres://localhost/stacks_test_shipgrade RAILS_ENV=test bin/rails test …`.
Never commit `db/schema.rb`.

Decided and NOT changing (Hugh approved these in the design): the score words "Nailed it / Partly /
Missing" and their colours, the panel title "How it scored", the panel order, no permissions change.

## Task 1: one definition of "previous ship"

- Add `WeeklyShip.previous_to(ships)`: the grader's query moved verbatim (corpus_eligible, any tracker
  among `ships`, a different document, `sent_at` before the earliest of `ships`, newest first, then
  `id desc` as a tie-break, `includes(:document)`). `Grader#previous_ship` calls it. Grader behaviour
  must not change; the grader tests must stay green untouched.
- `WeeklyShip#previous_ship` becomes `WeeklyShip.previous_to(WeeklyShip.where(document_id: document_id).to_a)`.
- Continuity row when `continuity_counted == false`: grey pill "First ship, not counted" when
  `previous_ship` is nil, otherwise "Not counted". No reason text either way. The grey pill needs
  `style: "background-color: #e3e5e7;"` (a bare `.pill` has no background).
- Tests: a corpus-excluded earlier ship gives no "Previous ship" panel; a first-ship test that would
  fail if the panel appeared for the wrong reason (create a later ship, not only an absence).

## Task 2: links only where the reader can follow them

- Trackers index pill and the tracker page's Weekly Ships panel: render the stars as a link only when
  `authorized?(:read, ship)`; otherwise the same stars as plain text. Ship scans index is admin/lead
  only already; leave it.
- Test: a user whose only access is a project-scoped lead grant (see `test/integration/admin_permission_grants_test.rb`
  for how to build one) sees the stars on the tracker page with no link to `admin_weekly_ship_path`.

## Task 3: no crash or nonsense on odd data

- `WeeklyShip#display_title`: `document.title.presence || "Weekly ship, #{sent_at.strftime("%B %-d, %Y")}"`.
  Use it for the page title and the previous-ship link.
- `WeeklyShip#sender_label`: `sent_by_name.presence || sent_by_email.presence || "Unknown sender"`.
  Use it on the ship page and (first word) in the index pill.
- "How it scored": take `dimensions` only if it is a Hash; keep a row only when the stored value is a
  Hash whose score is 0, 1 or 2; omit the whole panel when no rows remain.
- `WeeklyShip.pill_class`: stars that are not an Integer count as ungraded.
- Tests: nil title; both sender fields nil; `dimensions: []`; a dimension with no score; `stars: "5"`.

## Task 4: what the screenshots showed

All in `app/admin/project_trackers.rb` and `app/admin/weekly_ships.rb`.

- Pill links: add `font-size: inherit;` to `link_style` (the global `a` rule made the pill 18px).
  Same on the stars link in the tracker panel and the ship scans index. "Open ↗" in the tracker panel
  gets `white-space: nowrap`.
- Pill hover says what a click does and why the colour: `WeeklyShip.pill_reason(staleness:, stars:)`
  returns nil when green, else e.g. "Orange: the last ship scored 3 of 5." /
  "Orange: the last ship is more than 10 days behind the project's last logged hours." /
  "Red: … more than 30 days …" / "Red: the last ship scored 2 of 5." (when both apply, the reason
  for the worse colour; when tied, staleness first then grade, joined by a space).
  Stars title: "Open the coaching for this ship." plus the reason. Email link title: "Open the email."
  plus the reason. An unlinked stars span gets the reason only.
- "For next time": `list-style: decimal` on each `li`; the `ol` at `font-size: 16px; line-height: 1.5`.
  Summary `para` at 16px. "Not graded" `para` at 16px.
- The never-share line moves directly under the top table: 13px, no italics, no opacity:
  "This is coaching for the Project Lead who sent the ship. Stacks scores each ship overnight against
  what a great ship does. Never share it with the client."
- "Not graded" copy, two cases by `sent_at`:
  - within `Grader::WINDOW`: "This ship has not been graded yet. Ships are graded overnight once they
    are linked to a project, so check back tomorrow."
  - older: "This ship has no grade. Only ships sent in the last 14 days are graded, and this one was
    older than that when it was linked or when grading began." (use the WINDOW constant for the number)
- Previous ship line: no space before the comma.
- Top table title "This ship" (not "Weekly Ship Details").
- Linking block: "Linked by" shows "Stacks (automatic)" for `llm` and "A person" for `human`;
  confidence as a whole percent, blank when nil.
- Tracker panel wording: column "Feedback for the Project Lead"; footer "Grades are coaching for the
  Project Lead who sent the ship, scored overnight by a model. Never share them with the client."
  Update the existing assertion in `admin_project_tracker_show_test.rb` if it names the old text.
- Tests assert: the pill anchors carry `font-size: inherit`; numbered list style; both "Not graded"
  texts; the reason strings from `pill_reason` for each cell of the colour matrix.

## Finish

- Update the spec where behaviour changed (previous ship definition, unlinked stars, odd data, copy).
- Full run: `bin/rails test test/integration test/models/weekly_ship_test.rb test/models/project_tracker_weekly_ships_test.rb test/models/project_tracker_weekly_ship_summary_test.rb test/lib/stacks/weekly_ships test/services/mcp`, 0 failures.
- Commit spec, plan and code; push to the PR branch. Do not merge.

## Amendments after the plan review (these override anything above)

1. **Authorization is checked once per request, never per row.** `can_open_ships = authorized?(:read, WeeklyShip)`
   above the index column block's use and above `table_for` in the tracker panel. The adapter's answer
   for a WeeklyShip depends only on the user. No new per-row queries on the unpaginated index.
2. **Titles.** The outer pill span always carries `title: pill_reason` (nil when green), so a pill with
   no links still explains itself. The stars link title is `"#{summary} Open the coaching for this ship."`
   (summary kept, as the spec says; just the action sentence when the summary is blank). The email link
   title is "Open the email." Update the existing title assertion to match.
3. **`pill_reason` strings, exactly.** One private severity pair feeds both `pill_class` and `pill_reason`.
   - stale: "Orange: the last ship is more than 10 days behind the project's last scheduled hours."
   - overdue: "Red: the last ship is more than 30 days behind the project's last scheduled hours."
   - ★3: "Orange: the last ship scored 3 of 5."
   - ★1 or ★2: "Red: the last ship scored N of 5."
   - tied (stale and ★3, or overdue and ★1/★2): one prefix, e.g. "Orange: the last ship is more than 10
     days behind the project's last scheduled hours, and it scored 3 of 5."
   - otherwise the reason for the worse colour only. Derive 10 and 30 from the same constants
     `ProjectTracker.ship_staleness` uses if they exist as constants; otherwise literal.
   - Test all 18 cells (3 staleness × stars nil, 1..5): class as in the matrix, and reason nil exactly
     when the class is `pill exceptional`.
4. **Previous ship.** `WeeklyShip.previous_to(ships)` is the grader's query plus one change: order
   `order(sent_at: :desc, id: :desc)` (deterministic only when two different emails share a `sent_at`).
   Because it spans every tracker the email is linked to, the Previous ship panel shows the previous
   ship's project name when it differs from this ship's project. Add a two-tracker test.
5. **"Not graded" has three cases**, and the page first falls back to a sibling row's grade
   (`resource.grade || WeeklyShip.where(document_id: resource.document_id).filter_map(&:grade).first`):
   - email not corpus eligible (use whatever predicate/scope `Document.corpus_eligible` implies; a
     `Document.corpus_eligible.exists?(id:)` check is fine): "This ship is not graded because its email
     is excluded from Stacks search."
   - sent within `Grader::WINDOW`: "This ship has not been graded yet. Ships are usually graded overnight
     once they are linked to a project."
   - older: "This ship has no grade. Only ships sent in the last 14 days are graded, and this one was
     older than that when it was linked or when grading began."
   Tests assert each sentence and that the other two are absent.
6. **Tests must be able to fail.**
   - `WeeklyShip.pill_class(staleness: :fresh, stars: "5") == "pill exceptional"` as a unit assertion.
   - First ship: a later ship on the same tracker plus an earlier ship on a different tracker; assert
     "First ship, not counted" and no "Previous ship" panel.
   - "Not counted": `continuity_counted: false` with an earlier eligible ship; assert "Not counted",
     no "First ship", and the Previous ship panel present.
   - Scoped grantee (`PermissionGrant.create!(admin_user:, permission: "lead", subject: pt, granted_by:)`):
     `assert_response :success` on the trackers index and the tracker page, stars present, no
     `admin_weekly_ship_path` href; and the admin-side positive on the same pages. If the tracker page
     fails for a scoped grantee for reasons unrelated to this change, test the index only and report it.
   - Exclude a document in tests with `doc.update_columns(excluded: Document.excludeds[:manually_excluded])`.
   - Assert the "This ship" table title, and add an assertion for the new tracker-panel wording
     (there is no old assertion to update).
7. **Odd data.** A score counts only when it is an Integer 0, 1 or 2. Suggestions: keep only non-blank
   Strings; omit "For next time" when none. When there is no sender at all, the pill drops the "by …"
   part rather than saying "by Unknown". Use `display_title` and `sender_label` also in the weekly ships
   index and the tracker panel's Subject and Sender columns. Do NOT touch the sender the grader sends
   to the model.
8. **The never-share line stays where the spec has it** (after Previous ship, before the linking block).
   Only its style and wording change: 13px, no italics, no opacity.
9. Confidence shows as `(confidence * 100).round`%.
