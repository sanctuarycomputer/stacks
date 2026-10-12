# Project log: what Stacksbot has seen about a project, on the tracker

Date: 2026-10-12. Draft for Hugh's review. Spans two repos: Stacks (this one) and Stacksbot.

## Why

Project risk today is pulled out of people in meetings. Stacksbot already watches the places where
risk first shows (the project's Twist channel, Meet transcripts, mail to ships@) and writes what it
sees to Notion. None of that is visible from a project tracker, because almost nothing Stacksbot
writes is tied to a tracker.

The goal is a log per project tracker of what was seen, marked positive, neutral or negative, so risk across
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

## Who does what

Stacksbot is smart and Stacks is dumb. Every judgement about an observation is made by Stacksbot and
written to Notion. Stacks stores what its own admins enter, syncs, filters and draws, and no rule in
Stacks decides what an observation means.

One kind of intelligence does belong in Stacks: matching inside a pipeline Stacks owns. Stacks
ingests the raw Meet transcripts and ship emails, so matching those documents to a tracker happens in
Stacks too, as the weekly ship matcher already does.

| Stacksbot decides | Stacks does |
|---|---|
| Which project an observation belongs to | Holds the tracker's Twist channel and Notion project |
| Whether an observation is project signal at all | Shows rows Stacksbot marked, hides the rest by default |
| Which way it points (valence) | Colours the pill |
| How serious it is, and what folds into a Problem | Sorts by the fields Stacksbot wrote |
| Which project a Twist message belongs to (by channel) | Matches the documents it ingests (Meet, ship mail) to trackers |
| | Checks which project channels the Stacksbot account can see, and raises a task for a "no" |

There are no privacy features specific to this feature. The corpus already excludes one-on-ones,
reviews and the like before Stacksbot ever reads a transcript, and the log is shown only to people
who can read the tracker.

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

The third needs to know what Stacksbot can see. Stacks can answer that itself: its Twist token is
the Stacksbot account (checked 2026-10-12: user "Stacksbot", workspace 133876, 31 channels). A daily
task `stacks:sync_twist_channel_access` lists the channels that account belongs to once, and stores on
each tracker with a Twist link `twist_channel_accessible` and `twist_channel_checked_at`. A tracker
never checked raises no task; only a checked "no" does. Saving a new channel URL clears both, so a
stale answer never outlives the link it was about. If the Twist call fails, nothing is changed.

## Part 3. Observations carry what the log needs (Stacksbot)

- **Join.** The entity registry takes each project's trackers from `notion_project_id` in
  `list_project_trackers`. The name match is removed.
- **Attribution by place.** A Twist message in a channel that a tracker names gets that tracker's
  Project, with no text matching. Mail gets its Project from the tracker Stacks already linked the
  ship to (`list_weekly_ships`). A Meet observation gets its Project from the tracker Stacks matched
  the transcript to (Part 3a). The text resolver stays as the fallback for anything else.
- **Valence.** New select property on Observations: Positive, Neutral, Negative. It says only which
  way the news points. Setting it is also Stacksbot's statement that the row is project signal: a
  sensor sets a valence only when the row is worth a Project Lead's attention (today's rule of thumb:
  a Risk, Win, Decision, Commitment or Timeline Change of Medium or High salience). Every other row
  leaves it empty. The rule lives in the observe skill, where it can be tuned without a Stacks deploy.
  - Positive: a win, praise, something delivered.
  - Neutral: a decision, a commitment or a change that is neither good nor bad news on its face.
  - Negative: a problem, a slip, a complaint, a risk.
  How serious it is stays where it already lives: `Salience` on the observation, and `Severity`,
  `Status` and `Owner` on the Problem it is folded into. "Escalated" is not a judgement Stacks makes.
  It is a plain filter over fields Stacksbot wrote: a Negative observation that is High salience, or
  that belongs to a Problem nobody owns (`Status` Open) of severity High or Critical.
- **Problems inherit the Project** of their source observations when all of them agree.
- The Observations `Type` select has stray options ("High", "Medium", "business"). Left alone.

## Part 3a. Stacks matches Meet transcripts to trackers

Stacks ingests the transcripts, so it matches them, in the nightly ETL beside the ship matcher.

- New table `document_project_trackers`: `document_id`, `project_tracker_id`, `matched_by`
  (llm or human), `confidence`, `rationale`. One scan record per document, as `ship_scans` is for
  ships, so a document is matched once and again only when its content changes.
- `Stacks::Etl::ProjectMatcher`, modelled on `Stacks::WeeklyShips::Sweep`: one cheap model call per
  corpus-eligible `meet` or `gemini_notes` document from the last 14 days. It is given the meeting
  title, the attendees and the opening of the transcript, and the active trackers with their names,
  client and team. It answers with zero or more trackers, a confidence and a reason. A link is made
  at 0.6 or above. Most internal meetings match nothing, and that is a normal answer.
- The two documents of one meeting (transcript and Gemini notes) share a result.
- `list_documents` and `get_document` return `project_tracker_ids`, so Stacksbot's Meet sensor sets
  the Project without guessing.
- A person can correct a link from the document's admin page; a corrected document is never
  rematched. Ship emails keep their own matcher and table.

## Part 4. Stacks reads the Notion tables

- New sync mode for large tables, beside the existing whole-database one: query with a filter, upsert,
  never delete.
  - Observations: `Projects` is not empty, edited in the last 3 days (first run: last 90 days).
  - Problems: `Project` is not empty, same windows.
- Rows land in `notion_pages`, as Leads do. Wrappers `Stacks::Notion::Observation` and
  `Stacks::Notion::Problem` read the fields, as `Stacks::Notion::Lead` does.
- `ProjectTracker#observations` and `#problems` look rows up by `notion_project_id`. A jsonb index on
  the relation ids keeps this off a table scan.
- A row trashed in Notion disappears from the log on the next sync (trashed rows are requested
  explicitly for the window and soft-deleted).

## Part 5. The log page

`ActiveAdmin.register_page "Log"`, `belongs_to :project_tracker`, at
`/admin/project_trackers/:id/log`. Built from the tracker page's dashboard modules. The view is a
`?view=` parameter, shown as tabs.

| View | Shows | Default |
|---|---|---|
| Needs attention | Open Problems for the project, then Negative observations from the last 30 days, the escalated ones first | yes |
| Highlights | Every gated observation, all three valences, newest first, grouped by week | |
| Everything | Every observation synced for the project, gated or not, including dismissed | |

- **Gate** (Needs attention and Highlights): the row has a valence and its status is not Dismissed.
  Stacks applies no other test; what earns a valence is Stacksbot's call (Part 3).
- **A row**: valence pill (green Positive, grey Neutral or none, orange Negative, red when escalated), the observation's name
  and text, source and date, a link to the source, and the Problem it was folded into when there is
  one. Model-written text is escaped.
- **Filters**: source (Twist, Meet, mail, Notion) and valence, as chips, combinable with any view.
- **Empty states** say why: no Notion project chosen, no Twist channel, Stacksbot not in the channel,
  or nothing seen yet. Each links to the fix.
- **Tracker page**: one module beside Weekly Ships with the count of open Problems, the count of
  Negative observations in the last 30 days (and how many are escalated), the latest three rows and "Open the log →".
- **Trackers index**: out of scope for this pass. A risk column is the obvious next step once the log
  has earned trust.

## Order of work

1. Parts 1 and 2 (Stacks). One migration: `notion_project_id`, `twist_channel_accessible`,
   `twist_channel_checked_at`. Migrate before merging.
2. Part 3a (Stacks). One migration for the link and scan tables. Independent of step 1.
3. Part 3 (Stacksbot), after Hugh and the leads have filled in channels and projects for the active
   trackers. The Valence property is added in Notion first, by hand or by the same PR's setup step.
4. Parts 4 and 5 (Stacks), once two weeks of attributed observations exist to look at.

Each is its own PR. Step 1 is useful alone: it produces the list of projects with no channel.

## Tests

- Stacks: URL validation (good, wrong workspace, extra path, missing slash, two links); dropdown
  options; each task appears and clears; internal clients exempt; MCP fields; filtered sync never
  deletes; each view's gate; a scoped reader is refused; empty states.
- Stacks, Part 3a: a match at and under the threshold; no match; both documents of a meeting; a
  human correction is kept; an excluded document is never sent to the model; MCP fields.
- Stacksbot: registry join from tracker fields; channel attribution; Meet Project taken from Stacks;
  valence set only for project signal.

## Open questions

1. **Who sees the log?** Decided: whoever can read the project tracker. That is admins, leads, and a
   lead-in-training for the trackers they hold a grant on. The page checks `authorized?(:read, tracker)`.
2. **Valence.** Decided against Good / Bad / Ugly as stored values: it mixed direction with severity
   and had no neutral. See Part 3.
3. **Can Stacks check channel access itself?** Yes. Stacks's Twist token is the Stacksbot account, so
   Part 2 needs no write tool and nothing from Stacksbot.
4. **Meet.** Decided: Stacks matches transcripts to trackers, because Stacks ingests them (Part 3a).
5. **The Notion API version** Stacks uses is from 2021. The filtered query needs a relation filter and
   an edited-time filter. To verify against the real databases before Part 4 is planned.
