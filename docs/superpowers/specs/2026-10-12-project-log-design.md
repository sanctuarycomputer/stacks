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

7. A tracker may name one or many Twist channels and one or many Notion projects; at least one of each (2026-10-12).
1. Twist channel is a full URL, `https://twist.com/a/133876/ch/<id>/`. Only `<id>` may vary.
2. The tracker's Notion Project page is chosen from a dropdown, and is the join key.
3. An Observation reaches a tracker through its Project. No second attribution path.
4. No bespoke observations table. Stacks syncs the Notion tables and filters.
5. Observations are the first step of the loop, so the log leads with the few that need someone: its
   flags (Part 5). Everything else is further down the same page.
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

- **Twist channels.** Each stays a `project_tracker_links` row of type `twist_channel`. A tracker has
  one or many.
  - Stored shape: `https://twist.com/a/<workspace>/ch/<id>/`, where `<workspace>` is the configured
    Twist workspace id (133876) and only `<id>` varies.
  - People paste what the browser shows, so the link is tidied before it is checked: a thread URL
    (`…/ch/355509/t/6877281/`) or a missing trailing slash is cut back to the channel. Anything that
    is not a channel in our workspace is refused, with a message that shows the expected shape.
  - One or many per tracker. The same channel twice on one tracker is refused, validated on the
    tracker over links not marked for removal, so replacing a link in one form submit works.
  - Several trackers may name the same channel (one client, two trackers). Part 3 then sets every
    such tracker's Project on the observation.
  - `ProjectTracker#twist_channel_ids` returns the ids as a sorted Array of Integers, empty when
    there is none.
  - `ProjectTrackerLink` busts the task cache when it changes, as `ProjectTracker` does.
- **Notion projects.** New column `project_trackers.notion_project_ids`, an array: the Notion page
  ids, dashed, as `notion_pages.notion_id` stores them. A tracker has one or many. (It replaces the
  single `notion_project_id`, which stays in the table, ignored, until a follow-up drops it.)
  - The edit form shows a multiple select of Projects pages that are live, labelled "Title · Stage"
    because 14 live titles repeat, plus the tracker's current pages whatever their state.
  - Live means `Stage` is one of: Active, Ongoing/Maintenance, Upcoming/Legal Review, On Hold, Paused,
    Project Capsule Needed, Introduction, Pre-proposal Questions Needed, Proposal Needed, Proposal
    Sent, Following Up; or Completed and edited in the last 90 days. Pages ticked "🔴 Duplicated" are
    left out. This is Stacksbot's own list (`LIVE_STAGES`), copied so the two agree.
  - Several trackers may pick the same project.
  - Only an id being added is checked against the synced pages. If a chosen page is later removed
    from Notion, the tracker keeps the id and stays saveable, the form shows it as "(removed from
    Notion)", and the tracker counts as having no Notion project once none of its pages exists.
  - The unused `notion_homepage` link type is left alone.
- **Sync.** Add the Projects database (`713b28db…`, about 760 rows) back to the nightly Notion sync.
  Stacks still holds 698 rows from when it was last synced, in February 2025. Before building, fetch
  one live page with the Stacks client to confirm the `Stage` select reads as expected under the
  Notion API version Stacks uses.
- **MCP.** `list_project_trackers` returns `twist_channel_ids` and `notion_project_ids` (arrays, empty
  when there is none), so Stacksbot reads the mapping from Stacks and stops matching by name. The
  `update_project_tracker` tool's `twist_channel_url` description states the shape; it adds a channel
  beside the ones the tracker has and does nothing for one it already has.

## Part 2. Admin tasks (Stacks)

Two new task types in the existing computed task system
(`Stacks::TaskBuilder::Discoveries::ProjectTrackers`), for trackers that are in progress
(`ProjectTracker.in_progress`: not complete and not dormant) and not for an internal client. Each
clears itself when its condition ends.

| Task | Condition | Owner |
|---|---|---|
| Project tracker needs its Twist channel and Notion project linked | it has no Twist channel, or none of its Notion projects is a page that still exists | project leads, else admins |
| Stacksbot needs inviting to this project's Twist channel | the last check found Stacksbot is not in at least one of its channels | admins |

One task covers both missing links, so a tracker raises one task, not two. On day one that is about
28 tasks (the in-progress trackers), spread across their project leads. They also appear in
Stacksbot's weekly action-items list, which is the nudge we want.

The second task needs to know what Stacksbot can see. Stacks can answer that itself: its Twist token
is the Stacksbot account (checked 2026-10-12: user "Stacksbot", workspace 133876, 31 channels). A
daily task `stacks:sync_twist_channel_access` lists the channels that account belongs to once, and
stores on each tracker with a Twist link `twist_channels_inaccessible` (the ids among its channels
that the account is not in) and `twist_channel_checked_at`. Access is per channel, and one task
covers however many are missing. A tracker never checked raises no task; only a checked "no" does.
Adding, changing or removing a link clears both, so a stale answer never outlives the links it was
about. If the Twist call fails, nothing is changed and the system task is marked as an error.

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

Stacks ingests the transcripts, so it matches them, in the nightly ETL beside the ship matcher. The
two matchers are siblings and behave the same; the differences are listed at the end.

- **A project tracker has many meetings.** `ProjectTracker has_and_belongs_to_many :meetings`, through
  a plain join table with no model of its own.
- **`MeetingScan`**, the sibling of `ShipScan`: one per meeting, holding the outcome (linked, no match,
  out of scope), the model's confidence and reason for that meeting, a hash of what it read, and
  whether a person has locked it.
- **`Stacks::Meetings::Sweep`**, the sibling of `Stacks::WeeklyShips::Sweep`.
  - Always on, like the ship sweep. No switch. A preview task runs it without writing.
  - One cheap model call per meeting that has a corpus-eligible document and has not been scanned, or
    whose eligible content has changed since. Meetings older than 90 days are marked out of scope
    without a call.
  - A link is made at confidence 0.6 or above. The sweep adds links and never removes them.
  - A meeting a person has touched is locked and never rescanned.
- **What the model sees.** The meeting's title, the people present or speaking (by name or email),
  and the opening of its eligible documents. For each open client tracker: its names, its client, and
  its leads and recent team. Text from an excluded document is never sent, and the title is taken
  from an eligible document.
- **MCP.** `list_documents` and `get_document` return `project_tracker_ids` for a meeting's documents.
  The reason and confidence never leave Stacks.
- **Meeting Matches page** under Projects, for admins and leads, the sibling of the Weekly Ships page:
  a default "Needs Review" view, and add or remove a project on a meeting.
- **Volume.** About 330 eligible meetings in the 90-day window on the first night, then about ten a
  weekday. Roughly 4,000 input tokens each on the fast model.

Where it differs from the ship matcher, and why:

| | Ships | Meetings | Why |
|---|---|---|---|
| A match belongs to | the email | the meeting | a transcript and its Gemini notes are two documents of one meeting |
| Candidate trackers | every open tracker | open client trackers | a preview filed hiring interviews under internal trackers |
| What the model is told about a tracker | its names | its names, client and team | a meeting's title often names nobody; the people are the evidence |
| Cleanup | none | a scan and its links are removed when every document of the meeting has been excluded | an email is one document; a meeting can lose all of its |

## Part 4. Stacks reads the Notion tables

- New sync mode for large tables, beside the existing whole-database one: query with a filter, upsert,
  never delete. Every run is full (see "The sync is full every night" in Part 5).
  - Observations: `Projects` is not empty, edited in the last 90 days.
  - Problems: all of them, with or without a project.
- Rows land in `notion_pages`, as Leads do. Wrappers `Stacks::Notion::Observation` and
  `Stacks::Notion::Problem` read the fields, as `Stacks::Notion::Lead` does.
- `ProjectTracker#observations` and `#problems` look rows up by `notion_project_id`. A jsonb index on
  the relation ids keeps this off a table scan.
- A row trashed in Notion disappears from the log on the next sync (trashed rows are requested
  explicitly for the window and soft-deleted).

## Part 5. The log page

`ActiveAdmin.register_page "Log"`, `belongs_to :project_tracker`, at
`/admin/project_trackers/:id/log`. Built from the tracker page's dashboard modules. One page with no
view tabs (reworked 2026-10-13; an old `?view=` link still loads it and the parameter is ignored).

### What a flag is

Notion decides, not Stacks. Problems and Observations each carry a `Flag` formula whose result is
text: the reason, in a few words, when the page is a flag ("Open.", "Critical.", "Risk, not yet tied
to a problem."), and nothing when it is not. The whole rule is in that formula, including how recent
a page has to be (reworked 2026-10-13: Problems, Last Seen empty or within 30 days; Observations,
Observed At empty or within 30 days). Stacks does not describe the rule anywhere; the page links to
it ("See the rule in Notion ↗", the Problems database).

- `flag?` is true when the stored `Flag` text is not blank, and `flag_reason` is that text
  (`Stacks::Notion::Flag`, included by both wrappers). A boolean formula or a checkbox named `Flag` is
  read as yes or no too, with no reason text.
- What Notion states is final, yes or no. Stacks applies no window and no other test of its own to a
  page that carries `Flag`.
- The SQL the counts use reads the same property in the same order (`Stacks::ProjectLog.flag_sql`);
  a test holds it to the wrappers row by row.

Stacks adds view logic only, in one place (`Stacks::ProjectLog.flags_for`):

1. A **problem flag** is a flagged Problem under one of the tracker's Notion projects. A Resolved or
   Dismissed problem is never shown as one: a guard against a stale stored copy, not a rule.
2. An **observation flag** is a flagged Observation under one of the tracker's Notion projects that is
   not Dismissed (the same guard) and is not tied to a problem flag of (1) from either side (its
   `Problems` relation or the problem's `Source Observations`). A tied observation is shown under
   that flag as evidence, so nothing is counted twice.

A tracker's flag count is (1) + (2). Nothing in Stacks clears a flag. It goes when Notion's answer
changes and the next sync lands.

**Interim rule.** Only a page whose stored data has no `Flag` property (it was synced before the
property existed) falls back to `interim_flag?` on each wrapper, and only there does Stacks still
hold a 30-day window (`INTERIM_FLAG_WINDOW`): a Problem that is open, Critical or High, not Owned or
Mitigating and seen in the last 30 days; an Observation that is Negative, High salience, not
Dismissed and from the last 30 days. The page says so in one note, marked "Interim", when any row on
it used the rule. Delete the interim rule once every stored page carries `Flag`.

### The sync is full every night

`Flag` depends on today's date, and a formula's new result is not an edit of the page. A sync that
asked for pages edited since the last run would never see a flag lapse, so the nightly run (and
`rake stacks:sync_notion_log` by hand) re-reads everything: every Problem, and every Observation
that has a project and was edited in the last 90 days. A date-driven flip, or a rewritten formula,
lands within a day.

- Cost: one query per 100 rows. At about 405 Problems and 236 project-linked Observations that is
  5 + 3 = 8 requests a night.
- The recheck (rows asked for by id, at most 200 a run, to notice trash) now only covers rows the
  full query did not return, because every returned row is stamped as seen. Its brakes are unchanged:
  five failed fetches in a row, or a pass in which every fetch failed, stop it.
- The marks still record when each database last finished: the page's "Last synced", the "not synced
  yet" empty state, and the gate that keeps the log sync off the nightly task until a first run has
  been made by hand.
- `rake "stacks:sync_notion_log[incremental]"` keeps the old shape (rows edited since the last run)
  for a quick look after an edit in Notion. Nothing scheduled uses it.

### The page, top to bottom

1. **Flags**, with the count, "Notion decides what is a flag." and the link to the rule. Problem flags
   first (worst severity, then most recently seen), then observation flags (newest first). A row has
   a red "Flag" pill, the title, why it is a flag (Notion's text, then what Stacks holds about when
   it came up: "Seen 4 times, last on Oct 9, 2026." or "Seen in Twist on Oct 9, 2026."), "Stacksbot
   suggests:" (the Problem's `Proposed Action`, a suggestion and not an accepted owner; else a fixed
   line), up to five tied observations, and a link to Notion. With none: "No flags." and the link.
2. **Other open problems**, only when there are any: open Problems that are not flags. Severity and
   ownership in words ("Not picked up in Notion yet", "Owned by X", "Being mitigated by X"). Stacks
   gives no reason why one is not a flag when Notion answered. Under the interim rule only, it says
   "Not a flag: ..." (not seen for 30 days, or someone has it).
3. **Wins**, with the count: Positive observations of the last 30 days that are not Dismissed, newest
   first, 20 shown, with a link to all of them. These 30 days are a choice of the view
   (`WINS_WINDOW`), not part of the flag rule.
4. **All Observations**: every observation synced for the project, dismissed ones included, newest
   first, 200 a page. Source and valence filters and Newer/Older paging apply to this section only and
   their links land on it (`#all-observations`). The pill is the valence (green Positive, grey
   Neutral, orange Negative); a row with no valence shows its Notion Type in the same grey pill
   ("FYI", "Bug", "Decision"), and "Not marked" only when it has no Type either. A row that is a
   flag, or evidence of one, also says "Flag".

- Valence is Stacksbot's call (Part 3), with the interim Type mapping until it writes Valence.
- Everything from Notion is escaped, and only an http(s) address is ever linked.
- **Empty states** say why: no Notion project chosen, no Twist channel, Stacksbot not in the channel,
  or nothing seen yet. Each links to the fix.
- **Tracker page**: a "Flags" module above Weekly Ships with the flag count, the wins of the last 30
  days, the first three flags with why, and "Open the log →".
- **Trackers index**: a "Flags" column between "Last Ship" and "Forecast Projects": a red pill reading
  "3 Flags" ("1 Flag") that links to the log, blank when zero.
  `Stacks::ProjectLog.flag_counts(trackers)` counts the whole table in four queries from the same
  `flags_for`, so it equals what each log page lists. Blank, never an error, before the first sync or
  when the rows cannot be read.
- **"Has Flags" scope** on the index: exactly the trackers with a pill. Its ids are the keys of the
  same `flag_counts` (`Stacks::ProjectLog.flagged_tracker_ids`). The tab shows no count
  (`show_count: false`), so it is read only when the tab is opened.

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
- Stacks, Part 3a: a match at and under the threshold; no match; out of scope past 90 days; a meeting
  with two documents is matched once; text from an excluded document is never sent; a rescan never
  removes a link; a human correction is kept; MCP fields without the reason.
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
