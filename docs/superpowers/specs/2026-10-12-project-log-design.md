# Project log: what Stacksbot has seen about a project, on the tracker

Date: 2026-10-12. Draft for Hugh's review. Spans two repos: Stacks (this one) and Stacksbot.

## Why

Project risk today is pulled out of people in meetings. Stacksbot already watches the places where
risk first shows (the project's Twist channel, Meet transcripts, mail to ships@) and writes what it
sees to Notion. None of that is visible from a project tracker, because almost nothing Stacksbot
writes is tied to a tracker.

The goal is a log per project tracker of what was seen, marked good, bad or ugly, so risk across
projects can be read off Stacks without asking anyone.

## What exists (measured 2026-10-12)

- **Observations** (Notion, written by Stacksbot's sensors): 1,276 rows in the last two weeks. Each
  has a source, a permalink, a dedupe key, an event date, a salience and a type. 123 have a Project.
  1,086 are still untriaged. No valence, no confidence.
- **Problems** (Notion, folded from risk observations): about 400 open, with severity, owner, status
  and occurrence count. 24 have a Project.
- **Knowledge** (Notion, distilled nightly): about 800 timeless facts with a confidence. No project
  relation and no event date. Not a log, and not used here.
- **Join to a tracker**: Observation → Notion Project page → tracker, by name match. 13 of 135 live
  projects match.
- **Twist**: the `twist_channel` link type exists; no active tracker has one. On 2026-09-21 Stacksbot
  was in 27 channels, two of them project channels (not re-counted since).
- **Stacks Notion sync**: nightly, whole database, deletes rows it did not see. It can already read the
  Projects, Observations and Problems databases (checked: all three return 200).

## Decisions made with Hugh

1. Twist channel is a full URL, `https://twist.com/a/133876/ch/<id>/`. Only `<id>` may vary.
2. The tracker's Notion Project page is chosen from a dropdown, and is the join key.
3. An Observation reaches a tracker through its Project. No second attribution path.
4. No bespoke observations table. Stacks syncs the Notion tables and filters.
5. Observations are the first step of the loop, so the log shows a gated subset by default. Showing
   everything is a view, and not the default.
6. The log lives at `/admin/project_trackers/:id/log`.

## Non-goals

- No rebuild of the observation system, and no new sensor.
- No write from Stacks into Notion. Triage stays in Notion.
- No Twist ingestion into the Stacks corpus.
- No Knowledge table in Stacks.

## Part 1. A tracker names its sources (Stacks)

- **Twist channel.** Stays a `project_tracker_links` row of type `twist_channel`. New validation: the
  URL must match `\Ahttps://twist\.com/a/133876/ch/\d+/\z`, and a tracker has at most one.
  `ProjectTracker#twist_channel_id` returns the id. The workspace id comes from the Twist config, not
  a literal.
- **Notion project.** New column `project_trackers.notion_project_id` (the Notion page id). The edit
  form shows a dropdown of Projects pages in a live stage, plus the current value. Several trackers
  may pick the same project. The unused `notion_homepage` link type is left alone.
- **Sync.** Add the Projects database (`713b28db…`, about 760 rows) back to the nightly Notion sync.
  Stacks still holds 698 stale rows from when it was last synced.
- **MCP.** `list_project_trackers` returns `twist_channel_id` and `notion_project_id`, so Stacksbot
  reads the mapping from Stacks and stops matching by name.

## Part 2. Admin tasks (Stacks)

Three new task types for trackers whose work is not complete, in the existing computed task system
(`Stacks::TaskBuilder::Discoveries::ProjectTrackers`). Each clears itself when its condition ends.

| Task | Condition | Owner |
|---|---|---|
| Project tracker needs a Twist channel | no `twist_channel` link | project leads, else admins |
| Project tracker needs a Notion project | `notion_project_id` blank | project leads, else admins |
| Invite Stacksbot to this project's Twist channel | Stacksbot last reported it cannot see the channel | admins |

Internal clients are exempt from all three.

The third needs to know what Stacksbot can see. Stacksbot reports it: a new write tool
`report_twist_channel_access(project_tracker_id, accessible, checked_at)` stores the result on the
tracker (`twist_channel_accessible`, `twist_channel_checked_at`). Unknown is not a task; only a
reported "no" is. Open question 3 may make this simpler.

## Part 3. Observations carry what the log needs (Stacksbot)

- **Join.** The entity registry takes each project's trackers from `notion_project_id` in
  `list_project_trackers`. The name match is removed.
- **Attribution by place.** A Twist message in a channel that a tracker names gets that tracker's
  Project, with no text matching. Mail gets its Project from the tracker Stacks already linked the
  ship to (`list_weekly_ships`). Meet keeps the text resolver for now; see open question 4.
- **Valence.** New select property on Observations: Good, Bad, Ugly. Sensors set it for the signal
  types only (below). Other rows leave it empty.
  - Good: a win, praise, something delivered.
  - Bad: a problem the team is already handling.
  - Ugly: a risk to budget, timeline or the client relationship that nobody has owned yet.
- **Problems inherit the Project** of their source observations when all of them agree.
- **Channel check.** A weekly job compares each tracker's `twist_channel_id` with the channels
  Stacksbot is in, and calls `report_twist_channel_access` for each.
- The Observations `Type` select has stray options ("High", "Medium", "business"). Left alone.

## Part 4. Stacks reads the Notion tables

- New sync mode for large tables, beside the existing whole-database one: query with a filter, upsert,
  never delete.
  - Observations: `Projects` is not empty, edited in the last 3 days (first run: last 90 days).
  - Problems: `Project` is not empty, same windows.
- Rows land in `notion_pages`, as Leads do. Wrappers `Stacks::Notion::Observation` and
  `Stacks::Notion::Problem` read the fields, as `Stacks::Notion::Lead` does.
- `ProjectTracker#observations` and `#problems` look rows up by `notion_project_id`. A jsonb index on
  the relation ids keeps this off a table scan.
- Privacy: only project-linked rows are synced. Rows of type Morale, and Risk or Question rows that
  name a person, are skipped at sync, matching the rule Stacksbot's weekly post already applies.
- A row trashed in Notion disappears from the log on the next sync (trashed rows are requested
  explicitly for the window and soft-deleted).

## Part 5. The log page

`ActiveAdmin.register_page "Log"`, `belongs_to :project_tracker`, at
`/admin/project_trackers/:id/log`. Built from the tracker page's dashboard modules. The view is a
`?view=` parameter, shown as tabs.

| View | Shows | Default |
|---|---|---|
| Needs attention | Open Problems for the project, then Ugly and Bad observations from the last 30 days | yes |
| Highlights | Every gated observation, all three valences, newest first, grouped by week | |
| Everything | Every observation synced for the project, gated or not, including dismissed | |

- **Gate** (Needs attention and Highlights): has a valence, type is one of Risk, Win, Decision,
  Commitment, Timeline Change, salience is Medium or High, status is not Dismissed.
- **A row**: valence pill (green Good, orange Bad, red Ugly, grey when none), the observation's name
  and text, source and date, a link to the source, and the Problem it was folded into when there is
  one. Model-written text is escaped.
- **Filters**: source (Twist, Meet, mail, Notion) and valence, as chips, combinable with any view.
- **Empty states** say why: no Notion project chosen, no Twist channel, Stacksbot not in the channel,
  or nothing seen yet. Each links to the fix.
- **Tracker page**: one module beside Weekly Ships with the count of open Problems, the count of Ugly
  and Bad in the last 30 days, the latest three rows and "Open the log →".
- **Trackers index**: out of scope for this pass. A risk column is the obvious next step once the log
  has earned trust.

## Order of work

1. Parts 1 and 2 (Stacks). One migration: `notion_project_id`, `twist_channel_accessible`,
   `twist_channel_checked_at`. Migrate before merging.
2. Part 3 (Stacksbot), after Hugh and the leads have filled in channels and projects for the active
   trackers. The Valence property is added in Notion first, by hand or by the same PR's setup step.
3. Parts 4 and 5 (Stacks), once two weeks of attributed observations exist to look at.

Each is its own PR. Step 1 is useful alone: it produces the list of projects with no channel.

## Tests

- Stacks: URL validation (good, wrong workspace, extra path, missing slash, two links); dropdown
  options; each task appears and clears; internal clients exempt; MCP fields; filtered sync never
  deletes and skips the private types; each view's gate; a scoped reader is refused; empty states.
- Stacksbot: registry join from tracker fields; channel attribution; valence set only for signal
  types; the channel check with a fake Twist client.

## Open questions

1. **Who sees the log?** Assumed: admins and leads only, like ship coaching. Internal channels are
   blunt about clients and teammates.
2. **Bad versus Ugly.** The definitions above are mine. Hugh said valence makes sense but has not
   confirmed the line between the two.
3. **Can Stacks check channel access itself?** Stacks has its own Twist token. If that is Stacksbot's
   account, Stacks can test the channel directly and `report_twist_channel_access` is not needed.
   To verify before building Part 2.
4. **Meet.** A transcript has a title and attendees but no project. A matcher modelled on the weekly
   ship one would fix it. Left out of this pass unless the Meet rows turn out to matter most.
5. **The Notion API version** Stacks uses is from 2021. The filtered query needs a relation filter and
   an edited-time filter. To verify against the real databases before Part 4 is planned.
