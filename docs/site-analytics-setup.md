# Site Analytics (Google Analytics) — setup

Stacks syncs GA4 daily metrics for our own sites and serves them through the `get_site_analytics` MCP tool.
Nothing happens until step 4. Code: `lib/stacks/google_analytics.rb`, `lib/stacks/site_analytics_sync.rb`.

1. **Google Cloud project** (any project we own; a new one called `stacks-analytics` is fine):
   APIs & Services → Library → **Google Analytics Data API** → Enable.
2. **Service account**: IAM & Admin → Service Accounts → Create service account
   (name `stacks-analytics`; no project roles needed) → open it → Keys → Add key → Create new key → **JSON**.
   Note its email, e.g. `stacks-analytics@<project>.iam.gserviceaccount.com`.
3. **Viewer on each GA4 property**: in Google Analytics, for every site: Admin → Property → Property access
   management → **+ Add users** → the service account email → role **Viewer** → Add (untick "notify").
   While there, copy the **numeric Property ID** (Admin → Property settings → Property details;
   not the `G-…` measurement id).
4. **Key into Heroku** (then delete the downloaded file):
   `heroku config:set GOOGLE_ANALYTICS_SERVICE_ACCOUNT_JSON="$(cat stacks-analytics-key.json)" -a g3d-stacks`
5. **Sites**: Stacks admin → Dashboard → **Site Analytics** → New: name (how people will ask for it),
   site URL, GA4 property id. The next daily run (or **Sync now** on the site) backfills 13 months.

Client properties later: their admin adds the same service account email as Viewer, then add the row.
