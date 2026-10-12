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

- **Twist channel.** Stays a `project_tracker_links` row of type `twist_channel`.
  - Stored shape: `https://twist.com/a/<workspace>/ch/<id>/`, where `<workspace>` is the configured
    Twist workspace id (133876) and only `<id>` varies.
  - People paste what the browser shows, so the link is tidied before it is checked: a thread URL
    (`…/ch/355509/t/6877281/`) or a missing trailing slash is cut back to the channel. Anything that
    is not a channel in our workspace is refused, with a message that shows the expected shape.
  - At most one per tracker, validated on the tracker over links not marked for removal, so replacing
    the link in one form submit works.
  - Several trackers may name the same channel (one client, two trackers). Part 3 then sets every
    such tracker's Project on the observation.
  - `ProjectTracker#twist_channel_id` returns the id as an Integer, or nil.
  - `ProjectTrackerLink` busts the task cache when it changes, as `ProjectTracker` does.
- **Notion project.** New column `project_trackers.notion_project_id`: the Notion page id, dashed, as
  `notion_pages.notion_id` stores it.
  - The edit form shows a dropdown of Projects pages that are live, labelled "Title · Stage" because
    14 live titles repeat, plus the tracker's current page whatever its state.
  - Live means `Stage` is one of: Active, Ongoing/Maintenance, Upcoming/Legal Review, On Hold, Paused,
    Project Capsule Needed, Introduction, Pre-proposal Questions Needed, Proposal Needed, Proposal
    Sent, Following Up; or Completed and edited in the last 90 days. Pages ticked "🔴 Duplicated" are
    left out. This is Stacksbot's own list (`LIVE_STAGES`), copied so the two agree.
  - Several trackers may pick the same project.
  - If the chosen page is later removed from Notion, the tracker keeps the id, the form shows it as
    "(removed from Notion)", and the tracker counts as having no Notion project.
  - The unused `notion_homepage` link type is left alone.
- **Sync.** Add the Projects database (`713b28db…`, about 760 rows) back to the nightly Notion sync.
  Stacks still holds 698 rows from when it was last synced, in February 2025. Before building, fetch
  one live page with the Stacks client to confirm the `Stage` select reads as expected under the
  Notion API version Stacks uses.
- **MCP.** `list_project_trackers` returns `twist_channel_id` and `notion_project_id`, so Stacksbot
  reads the mapping from Stacks and stops matching by name. The `update_project_tracker` tool's
  `twist_channel_url` description states the shape.

## Part 2. Admin tasks (Stacks)

Two new task types in the existing computed task system
(`Stacks::TaskBuilder::Discoveries::ProjectTrackers`), for trackers that are in progress
(`ProjectTracker.in_progress`: not complete and not dormant) and not for an internal client. Each
clears itself when its condition ends.

| Task | Condition | Owner |
|---|---|---|
| Project tracker needs its Twist channel and Notion project linked | either is missing | project leads, else admins |
| Invite Stacksbot to this project's Twist channel | the last check found Stacksbot is not in it | admins |

One task covers both missing links, so a tracker raises one task, not two. On day one that is about
28 tasks (the in-progress trackers), spread across their project leads. They also appear in
Stacksbot's weekly action-items list, which is the nudge we want.

The second task needs to know what Stacksbot can see. Stacks can answer that itself: its Twist token
is the Stacksbot account (checked 2026-10-12: user "Stacksbot", workspace 133876, 31 channels). A
daily task `stacks:sync_twist_channel_access` lists the channels that account belongs to once, and
stores on each tracker with a Twist link `twist_channel_accessible` and `twist_channel_checked_at`.
A tracker never checked raises no task; only a checked "no" does. Changing or removing the link
clears both, so a stale answer never outlives the link it was about. If the Twist call fails,
nothing is changed and the system task is marked as an error.

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

## Part 3a. Stacks matches meetings to trackers

Stacks ingests the transcripts, so it matches them, in the nightly ETL beside the ship matcher.

- **Keyed on the meeting, not the document.** A meeting has one to three documents (a transcript,
  Gemini notes, or both), all pointing at one `Meeting` row. The match belongs to the meeting.
  - `meeting_project_trackers`: `meeting_id`, `project_tracker_id`, `matched_by` (llm or human),
    `confidence`, `rationale`. Unique on the pair.
  - `meeting_project_scans`: one per meeting, with `outcome` (linked, no_match), `scanned_hash`,
    `scanned_at`, `human_locked`. A meeting is matched once, and again only when the content of its
    eligible documents changes.
- **`Stacks::Meetings::ProjectMatcher`**, modelled on `Stacks::WeeklyShips::Sweep`. One cheap model
  call per meeting from the last 14 days that has at least one corpus-eligible document.
  - About the meeting: its title, the names of its participants and speakers, and the opening of its
    eligible documents (first chunks, 2,000 characters). Text from an excluded document is never sent.
  - About each in-progress tracker: its name, its Forecast project names, its client's name, and the
    names of its current leads and of people with hours on it in the last 60 days.
  - Matching is by name; the meeting data carries no emails.
  - The answer is zero or more trackers, a confidence and a reason. A link is made at 0.6 or above.
    Most internal meetings match nothing, and that is a normal answer.
- **Rematching.** A no-match meeting inside the window is tried again when a tracker has been created
  since its scan (a kickoff call often comes before the tracker).
- **Exclusion.** When a document is excluded from the corpus, its meeting's model-made links and scan
  are removed, so the next run rematches from whatever is still eligible, or not at all.
- **Volume.** About 100 eligible meetings a fortnight, so roughly seven calls a night.
- **MCP.** `list_documents` and `get_document` return `project_tracker_ids` for a meeting's documents.
  The rationale is never returned over MCP.
- **Correcting a match.** A "Meeting Matches" page under Projects, for admins and leads, modelled on
  the Weekly Ships page: the meeting, its date, the matched trackers with confidence and reason, and
  a default "Needs review" view of low-confidence and unmatched client-looking meetings. A person can
  add or remove a link; a meeting a person has touched is never rematched.
- Ship emails keep their own matcher and table.

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
   `twist_channel_checked_at`.
2. Part 3a (Stacks). One migration for the two tables. Independent of step 1.
3. Part 3 (Stacksbot), after the project leads have linked channels and projects on the in-progress
   trackers. The Valence property is added in Notion first.
4. Parts 4 and 5 (Stacks), once two weeks of attributed observations exist to look at.

Stacks deploys `main` without running migrations, so for steps 1 and 2 the migration is run on
production before the PR is merged. `db/schema.rb` is hand-edited in this repo (pgvector is left out
on purpose): add the new columns and tables by hand, never commit a raw dump.

Each is its own PR. Step 1 is useful alone: it produces the list of projects with no channel.

## Tests

- Stacks, Parts 1 and 2: the link is tidied (thread URL, missing slash) and refused (wrong workspace,
  not Twist, two links); replacing a link in one submit; the seven existing test sites that use
  `https://twist.com/a/1/ch/…` are updated; dropdown options and labels, a removed page; the combined
  task appears, clears, skips dormant, complete and internal trackers; the invite task follows the
  channel check and clears when the link changes; a failed Twist call changes nothing; MCP fields.
- Stacks, later parts: filtered sync never
  deletes; each view's gate; a scoped reader is refused; empty states.
- Stacks, Part 3a: a match at and under the threshold; no match; a meeting with two documents is
  matched once; text from an excluded document is never sent; excluding a document removes the
  model's links; a no-match is retried after a new tracker; a human correction is kept; MCP fields
  without the rationale.
- Stacksbot: registry join from tracker fields; channel attribution; Meet Project taken from Stacks;
  valence set only for project signal.

## Notes for the later parts

- Never run the whole-database sync and the filtered sync on the same Notion database: the first
  deletes every row under that database it did not see.
- `NotionPage#status_history` reads a database id that no longer exists and raises. Do not reuse it.
- Two trackers that share a Twist channel but name different Notion projects are allowed. Stacksbot
  sets both Projects on an observation from that channel.

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
