# Weekly Ship Grading — design (as built)

**Date:** 2026-09-28 · **Builds on:** stacksbot PR #186 (options doc, `2026-09-22-weekly-ship-grading-options.md`)
· **Status:** built, off until `WEEKLY_SHIP_GRADING=on`

## What it does

Every weekly ship email that the nightly sweep links to a tracker gets graded once, the same night: 1 to 5
stars, a one-line summary of what it does well, and one to three concrete, kind suggestions for the sender.
The grade is coaching for the Project Lead. It is never shown to the client.

## Decisions (one line of reasoning each)

- **Stacks grades, not a Stacksbot job.** #186 chose "Stacksbot grades, Stacks stores" so the grader could
  read the week's Twist and transcripts. Building it showed the email alone carries almost the whole rubric,
  and grading in the sweep costs one Haiku call per email (~2.6k tokens in, ~470 out: about $0.005, so
  ~$0.15 a month for ~30 ships; ~$6 even if the 40-a-night cap were hit every night)
  against an agent session per ship, with no new Job, no sub-agent fan-out and no MCP write tool. Corpus
  cross-checks ("did it really land") are a later, optional layer.
- **Storage:** `weekly_ships.metadata` jsonb, grade under `scoring` (as #186 decided). A multi-tracker email
  has several rows; every row gets the same grade.
- **Model:** `Stacks::AI` `:fast` tier (claude-haiku-4-5), structured output. The model scores seven
  dimensions 0/1/2 with a one-sentence reason each; **stars are computed in code**, so the mapping is exact
  and testable.
- **Rubric v1** (#186's seven, adjusted): shipped not busy · next week is a promise · risks and asks visible ·
  timeline explicit · money visible · readable by the client · continuity with the previous ship. Dropped
  from #186: *cadence* (the "Needs you" missing-ship check already owns it) and *numbers match Stacks*
  (half of real ships report money in their own format; the block is one acceptable form). Continuity is
  not counted for a first ship.
- **Stars:** share of available points: ≥0.9 ★5, ≥0.7 ★4, ≥0.5 ★3, ≥0.25 ★2, else ★1 (reproduces
  #186's 13–14/10–12/7–9/4–6/0–3 on 14 points).
- **When:** `stacks:etl:match_weekly_ships` runs the sweep, then the grader: ungraded ships sent in the last
  14 days, newest first, at most 40 a night. A failure writes nothing and retries next night; the task
  is marked errored. Grade once; no regrade on reply.
- **Self-check:** a grade with an out-of-range score, no summary or no suggestions is rejected, never
  stored. Em dashes are stripped. `rake "stacks:etl:grade_weekly_ships_preview[10]"` prints grades without
  saving, for calibration.
- **Trust gate:** off until `heroku config:set WEEKLY_SHIP_GRADING=on`. The preview ignores the gate.

## Where people see it

- **Tracker page → Weekly Ships panel:** stars and the feedback for each ship (visible to the PL; not
  broadcast). Weekly Ships page: a Grade column. Ship detail: the seven scores with reasons.
- **MCP:** `list_weekly_ships`, `get_project_burnup`, `get_weekly_ship_block` rows and
  `list_project_trackers.last_weekly_ship` carry `grade {stars, summary, suggestions, rubric_version,
  graded_at}`, walled with the email (null when the email is excluded from the corpus).
- **Stacksbot:** the Monday team post celebrates five-star ships in Wins. Nothing lower is posted anywhere.
  The write-weekly-ship skill reads the previous ship's suggestions before drafting the next one.

## Calibration (2026-09-28, 12 real ships from the last 3 months)

Hand-graded blind first, then Haiku, twice: 12/12 within one star, 9/12 exact, 10/12 identical stars
across the two runs (the two flips were 4↔5). No systematic bias. Every Haiku ★5 was a ship the human rated
★4–5, and every Haiku ★2 was rated ★2–3, so "celebrate ★5 only, never post low grades" holds up.
Known weakness: suggestions occasionally misread a detail (one mistook an upcoming date as past).

## Not built (yet)

Human override of a grade; a per-sender trend view; corpus cross-checks; per-studio rubric variants.
