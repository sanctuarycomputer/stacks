# Stacks Surveys Observations — Status & Runbook

Contributor surveys (studio-wide `Survey` + `ProjectSatisfactionSurvey`) are an **observed** source in
stacksbot. The stacks-side enabler is the pair of read-only MCP tools `list_surveys` /
`get_survey_results` (PR #177, deployed 2026-09-09).

Spec: `docs/superpowers/specs/2026-09-09-survey-observations-mcp-design.md`.

## Status: LIVE (2026-09-09)

- **stacks:** `list_surveys` (kind/status/closed-range filters, counts + overall_score only) and
  `get_survey_results` (anonymous aggregates; free text only for closed surveys with ≥3
  responses, arrays sorted; open surveys withhold results). Verified against production: no
  responder identity appears in any payload.
- **Notion Sources DB → "Stacks Surveys"** (slug `stacks-surveys`, Backing Tool `stacks MCP`,
  Cite Label `Stacks/Surveys`, **Status: Active**):
  https://app.notion.com/p/3d6131fea2c781638d07de33c0f09341
- **Notion Jobs DB → "Observe: Stacks Surveys"** (daily `0 7 * * *` America/New_York,
  `Deliver To: none`, **Enabled: ON**, window contract `--default 7d --max 30d`):
  https://app.notion.com/p/3d6131fea2c7819fbcdee641924eca79
  Gateway cron name `notion:3d6131fea2c7819fbcdee641924eca79`.
- **Observations DB:** `Source` select option `Stacks/Surveys` added.

### First run (forced, 2026-09-10 00:16 UTC)
- 10 rows written: 5 close summaries (studio surveys 34/35/36 closed 2026-09-03; project
  surveys 1125/1126 closed late August) + 5 theme rows, each citing ≥2 supporting responses.
- People / Entities / Projects relations all blank; Observed At = each survey's `closed_at`;
  Source Ref = the Stacks admin results page.
- Immediate re-run → **0 written** (every survey gated on its `:closed` Source Key). Jobs row
  shows `Last Run Status: Success`.

## Source Keys
`stacks:survey:<kind>:<id>:closed` (the idempotence gate) · `stacks:survey:<kind>:<id>:theme:<slug>`
(≤3 per survey) · `stacks:survey:<kind>:<id>:stalled` (open 14–90 days with <50% response rate).

## Runbook

**Force a run / inspect results** (no SSH needed): the OpenCLAW gateway's WebSocket RPC at
`wss://stacksbot.garden3d.net/` accepts a client that presents itself as the Control UI
(`client.id: "openclaw-control-ui"`, `Origin: https://stacksbot.garden3d.net`, `auth.token` =
`OPENCLAW_GATEWAY_TOKEN` from the stacksbot sops bag). Then `cron.run {id, mode: "force"}` and
`cron.runs {scope: "job", id}` — the finished entry's `summary` is the run's final line
("Observe: Stacks Surveys done — N written"). `/tools/invoke` cannot do this (`cron` is denied)
and the Render box's SSH is not open to laptop keys.

**Preview the window** the next run will use (Notion key only):
`node scripts/observe-window.mjs --job 3d6131fea2c7819fbcdee641924eca79 --default 7d --max 30d --format json`
in the stacksbot repo.

**Tune without code:** theme count, salience thresholds, the stalled bounds and the privacy
rules live in the Sources row's `## Fetch` / `## Privacy` sections; Notion edits reach the agent
on the next `stacksbot-resync` (every 15 min).

## Known v1 limitations
- A survey that is reopened and re-closed keeps its original `:closed` key and is not
  re-observed.
- Themes are judged by the agent from free text; a survey with <3 responses yields no themes.
- Cross-survey synthesis is left to `propose-challenges` / the nightly distiller (by decision).
