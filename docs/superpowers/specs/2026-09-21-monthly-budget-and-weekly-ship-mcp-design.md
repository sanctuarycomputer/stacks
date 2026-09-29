# Monthly budgets + weekly-ship data over MCP — design

**Date:** 2026-09-21 · **Owner:** Hugh · **Status:** built on `feat/monthly-budget-weekly-ship-mcp`

## Why

Stacksbot's `write-weekly-ship` skill (stacksbot PR #181) reproduces the tracker page's
"✨ Weekly Ship Gmail Autoformatter ✨" from two MCP tools and a hand-copied template, and
finds the previous ship by keyword search over the corpus. Three things in Stacks make that
fragile: the formatter lives only in ERB, retainers have no monthly budget field (the
"Monthly Budget: $79,400" line in real ships comes from memory or the SOW), and the
`weekly_ships` table that PR #174 built is not exposed over MCP. This change closes all three
by extending the tracker tools that already exist rather than adding a weekly-ship tool.

## Decisions

1. **Monthly budget is a range**, `monthly_budget_low_end` / `monthly_budget_high_end`
   (nullable decimals on `project_trackers`). Entering one side mirrors it to the other
   before validation, so a fixed monthly budget is one number typed once. Low must be ≤ high.
   The overall band (`budget_low_end` / `budget_high_end`) stays as it is; a tracker can carry
   both ("stay under X per month, and the whole thing is Y").
   Note: the overall band still *rejects* a one-sided entry with the existing message rather
   than mirroring. Left alone here; aligning it is a one-line follow-up if wanted.
2. **The formatter block is rendered by the model**, `ProjectTracker#weekly_ship_block`, and
   both the ERB copy button and `get_project_burnup` use it. The block:

   ```
   ⏳ Hours Progress
   Trailing 7 days: <hours, 1dp> hours (<$>)

   💹 Budgetary Progress
   Invoiced: <$>
   Spend this Month: <$>
   Monthly Budget: <$>                      ← only with a monthly budget (Low End / High End
                                               lines when the two ends differ)
   Total Spend to Date: <$>                 ← only with an overall band
   Budget Low End: <$> / Budget High End: <$>   (or a single Budget: line when equal)
   ```

   Behaviour change: `Total Spend to Date` used to print unconditionally. It now prints only
   with an overall band, matching Hugh's rule for ships (a retainer's lifetime spend is not a
   number the client tracks) and what the retainer ships already do by hand.
3. **MCP read surface.** `get_project_burnup` gains `monthly_budget {low, high}`, `hours_7d`
   (tracker-wide, same window as the contributors tool), `considered_ongoing`,
   `weekly_ship_block`, and `last_weekly_ship {document_id, sent_at, sent_by, url}`.
   `list_project_trackers` gains `monthly_budget_low_end/high_end`, `considered_ongoing`, and
   `links[] {name, url, link_type}` (every row, not just MSA/SOW; `msa_url`/`sow_url` stay for
   compatibility; any embedded credentials are stripped). New tool
   `list_weekly_ships(tracker, limit)` returns the tracker's ships newest first with the
   document id, so `get_document` can fetch the body. Both it and `last_weekly_ship` skip
   ships whose document was excluded from the corpus, the same wall `get_document` enforces.
   Read-only, no LLM calls.
4. **MCP write surface.** `update_project_tracker` accepts `monthly_budget_low_end`,
   `monthly_budget_high_end` (one alone = fixed, both = range), `clear_monthly_budget`,
   `twist_channel_url`, `notion_homepage_url`. Two new `ProjectTrackerLink` types:
   `twist_channel` (10), `notion_homepage` (11). Link URLs are now validated as anchored
   http(s) URLs with a host and no credentials (the old `URI::regexp` matched a substring,
   so `javascript:alert(1)//https://x` passed); no existing row violates the new rule.
5. **Admin.** Monthly budget inputs on the tracker form; Monthly Budget rows in the money
   table; the copy button reads the shared block.

## Out of scope

Grading sent ships (step 2). `Stacks::AI` and `weekly_ships` make that a Stacks-native nightly
job; it gets its own spec. The stacksbot skill switches to `weekly_ship_block` and
`list_weekly_ships` after this deploys.

## Tests

Model: mirroring, low ≤ high, block variants (band only, monthly only, both, neither, equal
ends). Tools: new burnup fields, `list_weekly_ships`, serializer links, update-tool params.
