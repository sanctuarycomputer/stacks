# Weekly ship grades: the Last Ship pill and a coaching page

Date: 2026-10-12. Builds on `2026-09-28-weekly-ship-grading-design.md` (the grader).

## Why

Stacks has graded every weekly ship overnight since 2026-09-30. The grade is coaching for the
Project Lead who sent the ship, but it is hard to find: it does not show on the trackers index,
and the ship's own page is an attributes table with raw rubric keys ("Next week: 0/2") mixed in
with matcher internals. Two changes make the grade visible and useful.

## What Hugh asked for

1. Surface the latest grade on the "Last Ship" column of the Project Trackers index. Stars first,
   then timestamp and sender. Pill colour depends on both staleness and stars.
2. Style the weekly ship show page so it uses our language and works as a coaching surface for
   Project Leads.

## Non-goals

- No migration, no change to the grader's prompt, the rubric, the scoring or stored grades. Nothing is
  regraded. (The grader's "previous ship" query moved to `WeeklyShip.previous_to` so the page and the
  grader share it; see section 2.)
- No human override of a grade.
- No permissions change. Admins and leads can open the ship page today. Leads-in-training with
  project-scoped grants cannot, and that stays as it is until Hugh decides. They see the stars as
  plain text, not as a link that would be refused.
- No change to what Stacksbot reads over MCP (`grade_json`).

## 1. Last Ship pill

`app/admin/project_trackers.rb`, the "Last Ship" index column.

- Text: `★★★★☆ · 3 days ago by Leyna`. An ungraded ship has no stars and no separator. A ship
  with no sender name or address drops the "by ..." part.
- The whole pill is one link to the ship's page (`admin_weekly_ship_path`), graded or not. Its hover
  title is the grade's one-line summary, then "Open the coaching for this ship." The email is reached
  from the ship page ("Open in Google Groups", top right), not from the index.
- A reader who cannot open the ship page (`authorized?(:read, WeeklyShip)`, asked once per request,
  never per row) gets the same text with "↗", linked to the email in Google Groups instead, with the
  title "Open the email."
- The link sets `font-size: inherit`, because the global `a` rule would size it at 18px.
- Colour is the worse of staleness and grade, from `WeeklyShip.pill_class(staleness:, stars:)`:

  | | ★4 to ★5, or ungraded | ★3 | ★1 to ★2 |
  |---|---|---|---|
  | fresh (10 days or less) | green `exceptional` | orange `at_risk` | red `error` |
  | stale (11 to 30 days) | orange | orange | red |
  | overdue (over 30 days) | red | red | red |

- The pill's own hover title says why it is orange or red, from
  `WeeklyShip.pill_reason(staleness:, stars:)`. A green pill has no title. One private severity pair
  feeds both the class and the reason.
  - stale: "Orange: the last ship is more than 10 days behind the project's last scheduled hours."
  - overdue: "Red: the last ship is more than 30 days behind the project's last scheduled hours."
  - ★3: "Orange: the last ship scored 3 of 5."
  - ★1 or ★2: "Red: the last ship scored N of 5."
  - both at the same colour: "Orange: the last ship is more than 10 days behind the project's last
    scheduled hours, and it scored 3 of 5."
  - otherwise the reason for the worse colour only.
- Stars that are not a whole number count as ungraded.
- Unchanged: "No ships yet", the dash for internal clients and for the Complete tab, and the
  staleness anchor (last recorded Forecast date).
- No new queries. The index already loads the latest ship per tracker with its document.

## 2. The ship page

`app/admin/weekly_ships.rb`, `show`, laid out in `app/views/admin/weekly_ships/_show.html.erb` with
the same modules as the Project Tracker page (`.dashboard-modules`, `.dashboard-module`,
`.module-header`, `.module-body`, `.factoid`), not ActiveAdmin's default panels. Page title is the
email subject (`WeeklyShip#display_title`). The top-right actions include "Open in Google Groups ↗"
(the original email, in a new tab) when the email has a Groups link. Top to bottom:

1. Module "This ship": the project (linked, in the header), and two factoids: the stars with
   "n of 5", and how long ago it was sent with the sender and date.
2. Side by side: module "What this ship does well" (the grade's summary) and module "For next time"
   (the one to three suggestions, numbered).
3. Module "How it scored": one row per rubric dimension, with
   - the dimension's label and a line on what a great ship does (`Grader::GUIDE`),
   - a pill from `Grader::SCORE_LABELS`: 2 "Nailed it" green, 1 "Partly" orange, 0 "Missing" red,
   - the grader's reason.
   When `continuity_counted` is false the continuity row shows a grey pill and no reason: "First
   ship, not counted" when there is no previous ship, otherwise "Not counted".
4. Side by side: module "Previous ship" (the previous ship, linked to its own page, with how long ago
   it was sent and its stars; omitted when there is none) and a note module: "This is coaching for
   the Project Lead who sent the ship. Stacks scores each ship overnight against what a great ship
   does. Never share it with the client."
5. Muted module "How this email was linked to the project": Linked By ("Stacks (automatic)" or
   "A person"), Confidence as a whole percent (the row is left out when there is none), Rationale.

### Previous ship

One definition, `WeeklyShip.previous_to(ships)`, used by the page (`WeeklyShip#previous_ship`) and by
the grader, so the page shows the ship the grader compared against. Given every row for one email, it
is the newest earlier ship that

- is a different email,
- is on any project this email is linked to,
- was sent before this email,
- and whose email is still in Stacks search (corpus eligible).

Newest first by `sent_at`, then by id, so two emails sent at the same moment give a stable answer.
Because it spans every project the email is linked to, the panel names the previous ship's project
when it is not the project of the row being viewed.

### Not graded

The page reads the grade from this row, or from another row for the same email (a project linked
after the email was graded gets its own copy only if the grader runs while the ship is inside its 14-day window, so the page reads the grade from any row of the email; the index pill does not, and shows such a row without stars). With no grade at all, a "Not
graded" module replaces 2 and 3 and says one of:

- the email is excluded from Stacks search: "This ship is not graded because its email is excluded
  from Stacks search."
- sent within `Grader::WINDOW`: "This ship has not been graded yet. Ships are usually graded
  overnight once they are linked to a project."
- older: "This ship has no grade. Only ships sent in the last 14 days are graded, and this one was
  older than that when it was linked or when grading began."

### Odd data

Stored grades are model output and old rows vary, so the page shows only what has the right shape and
never crashes on the rest.

- No subject: "Weekly ship, October 5, 2026" (`display_title`), on this page, the previous-ship link,
  the weekly ships index and the tracker panel.
- No sender name: the email address; neither: "Unknown sender" (`sender_label`). The grader still
  sends the model what it always did.
- A dimension row shows only when its stored value is a Hash whose score is the Integer 0, 1 or 2.
  "How it scored" is left out when no rows remain, or when `dimensions` is not a Hash.
- "For next time" keeps only non-blank Strings and is left out when there are none.
- "What this ship does well" is left out when the summary is blank.
- Stars that are not an Integer are not a grade: the page says "Not graded" and the pill has no stars.

### Our language

| Key | Label |
|---|---|
| `shipped` | Shipped, not busy |
| `next_week` | Next week is a promise |
| `asks` | Risks and asks are visible |
| `timeline` | Timeline is explicit |
| `money` | Money is visible |
| `readable` | Readable by the client |
| `continuity` | Picks up where the last ship left off |

`GUIDE` sits beside `DIMENSIONS` in the grader. The model scores against `DIMENSIONS`; people read
`GUIDE`. A test asserts the two have the same keys in the same order.

## 3. Ways in

The stars in the tracker page's Weekly Ships panel and in the Weekly Ships list (ship scans index)
link to the ship page. In the tracker panel a reader who cannot open the ship page sees plain stars,
as on the index. The Weekly Ships list is for admins and leads only, so its stars always link.

The tracker panel's feedback column is "Feedback for the Project Lead", and its footer reads "Grades
are coaching for the Project Lead who sent the ship, scored overnight by a model. Never share them
with the client."

## Privacy and safety

- Grades are internal. Every surface here is inside ActiveAdmin behind `AdminAuthorization`.
- All model-written text (summary, suggestions, reasons) is rendered through Arbre, which escapes it.
- A ship whose document was later excluded from the corpus still shows to admins and leads in
  ActiveAdmin, as it does today. The MCP tools are the wall for Stacksbot and are not touched.

## Tests

`test/integration/admin_weekly_ship_coaching_test.rb`: all 18 cells of the colour matrix with their
reasons; pill order, colour, titles and links; an ungraded pill; a reader with a project-scoped grant
(plain stars, no link) beside an admin; the coaching page; the previous ship (excluded email, first
ship, "Not counted", another project, a tie on `sent_at`); odd data; the three "Not graded" cases and
the sibling-row grade; the tracker panel wording; guide keys.
