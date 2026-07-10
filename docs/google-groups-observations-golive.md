# Google Groups Observations — Go-Live Checklist

Google Groups is authored as an **observed** source in stacksbot. The stacks-side enabler is
**live in prod** (`get_document` returns `source` + `root_message_id` for `google_groups` docs,
release v718). The Notion artifacts are authored; the **sensor is intentionally OFF** so you
validate the rubric's yield before it starts writing to the team-facing Observations DB + digest.

## What's already done
- **stacks (PR #132, deployed):** `get_document` exposes `root_message_id` (RFC822 root) so an
  observing agent builds the exact-thread Gmail link
  `https://mail.google.com/mail/#search/rfc822msgid:<root_message_id>`; the existing `url` is the
  group-archive browse link.
- **Notion Sources DB → "Google Groups"** (slug `google-groups`, Backing Tool `stacks MCP`,
  **Status: Active**): full `## Fetch` / `## Search` / `## Cite` contract. Source Key
  `stacks:groups:<root_message_id>`. Because it's Active, `recall` can already search
  `google_groups`.
- **Notion Jobs DB → "Observe: Google Groups"** (daily `0 6 * * *`, `Deliver To: none`,
  **Enabled: OFF**): the disabled sensor.

## To go live (you, when ready)
1. **Dry run first (recommended):** manually trigger the `observe` skill for source
   `google-groups` (or use the job's Trigger Phrase "run observe on google groups") over a small
   window. Confirm salient threads become Observations with `Source = Google Groups`, a working
   Gmail `rfc822msgid` backlink, and Source Key `stacks:groups:<root>`; confirm a Sentry/QuickBooks
   thread is *rejected*. Re-run immediately → **zero** new rows (deterministic-key idempotence).
2. **Enable the sensor:** set `Observe: Google Groups` → `Enabled = ✅`. The cron reconciler
   schedules it; it senses daily and its New observations flow into the existing Observations
   Digest.
3. **Watch the first few digests** for noise. If the all-groups firehose (`admin@`, `dev@`) leaks
   low-value rows, tune the `## Fetch` salience guidance in the Sources row (or narrow scope) —
   no code change.

## Known v1 limitations (see the spec)
- Window keys on `occurred_at` = thread **start**, so an old thread with a fresh reply isn't
  re-sensed until we add `last_message_at` filtering (small future stacks change).
- No historical backfill of the ~39k threads (forward-only); a one-time Workflow can add it later.
- Sender attribution isn't exposed for email — salience is judged on `body`.

Spec: `docs/superpowers/specs/2026-07-10-google-groups-observations-source-design.md`.
