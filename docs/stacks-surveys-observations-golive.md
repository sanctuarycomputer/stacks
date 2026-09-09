# Stacks Surveys Observations — Go-Live Checklist

Contributor surveys (studio-wide `Survey` + `ProjectSatisfactionSurvey`) are authored as an
**observed** source in stacksbot. The stacks-side enabler is the pair of read-only MCP tools
`list_surveys` / `get_survey_results`. The Notion artifacts are authored **Draft / disabled** so
the rubric's behaviour is validated before the sensor writes to the team-facing Observations DB.

Spec: `docs/superpowers/specs/2026-09-09-survey-observations-mcp-design.md`.

## What's already done
- **stacks:** `list_surveys` (kind/status/closed-range filters, counts + overall_score only)
  and `get_survey_results` (anonymous aggregates; free text only for closed surveys with ≥3
  responses, arrays sorted; open surveys withhold results). No responder identity ever crosses
  the wire.
- **Notion Sources DB → "Stacks Surveys"** (slug `stacks-surveys`, Backing Tool `stacks MCP`,
  Cite Label `Stacks/Surveys`, **Status: Draft**): `## Fetch` (close summary + ≤3 themes per
  newly closed survey, gated on the `:closed` Source Key; stalled open surveys 14–90 days old),
  `## Privacy` (binding: paraphrase, never attribute, never call contributor-listing tools for a
  survey's project/studio, never set People), `## Search`, `## Cite`.
- **Notion Jobs DB → "Observe: Stacks Surveys"** (daily `0 7 * * *` ET, `Deliver To: none`,
  **Enabled: OFF**).
- **Observations DB:** `Source` select option `Stacks/Surveys` added.

## To go live (you, when ready)
1. **Deploy stacks** so the two tools are live, then confirm from the agent:
   `list_surveys(status: "closed", limit: 3)` returns rows and
   `get_survey_results(kind, id)` on one of them returns `questions` / `free_text_questions`
   with no names or emails anywhere in the payload.
2. **Flip the Sources row to Active** (needed for the reconciler to materialize the contract
   into `skills/sources/stacks-surveys.md`). Recall can then answer "how do contributors feel
   about X" over closed surveys.
3. **Dry run:** trigger the `observe` skill for source `stacks-surveys` with an explicit window
   that contains one known closed survey (e.g. "the last 90 days"). Verify:
   - exactly one row with Source Key `stacks:survey:<kind>:<id>:closed` plus ≤3
     `…:theme:<slug>` rows, `Source = Stacks/Surveys`, Observed At = the survey's closed_at,
     Source Ref opens the Stacks admin results page;
   - no verbatim quotes, no attribution, People relation empty, Entities blank;
   - a survey with fewer than 3 responses produced the `:closed` row only;
   - re-run immediately → **zero** new rows.
4. **Seed history (optional):** the automatic window is capped at 14 days. Trigger the skill
   once more with "the last 365 days" to observe every survey closed in the past year. The
   `:closed` gate keeps this idempotent.
5. **Enable the sensor:** `Observe: Stacks Surveys` → `Enabled = ✅`. Its New observations flow
   into the existing Observations Digest and the weekly Propose Challenges pass.
6. **Watch the first few digests.** Tune theme count, salience thresholds, or the stalled
   bounds in the Sources row's `## Fetch` — no code change.

## Known v1 limitations
- A survey that is reopened and re-closed keeps its original `:closed` key and is not
  re-observed.
- Themes are judged by the agent from free text; a survey with <3 responses yields no themes.
- Cross-survey synthesis is left to `propose-challenges` / the nightly distiller (by decision).
