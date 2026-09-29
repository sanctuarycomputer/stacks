# Site Analytics (Google Analytics) — setup

Stacks syncs GA4 daily metrics for our sites and serves them through the `get_site_analytics` MCP tool.
It uses Stacks' EXISTING Google service account, **stacks@stacks-305217.iam.gserviceaccount.com** (the one the
Meet/Gmail ETL uses), directly: no new key, no domain-wide delegation. Code: `lib/stacks/google_analytics.rb`,
`lib/stacks/site_analytics_sync.rb`.

Two steps, both Hugh's:

1. **Enable two APIs in Google Cloud project `stacks-305217`**: APIs & Services → Library →
   **Google Analytics Data API** → Enable, then **Google Analytics Admin API** → Enable.
2. **Viewer at the GA account level**: in Google Analytics, Admin → **Account** access management →
   **+ Add users** → `stacks@stacks-305217.iam.gserviceaccount.com` → role **Viewer** → Add (untick "notify").
   Account level covers every property under it in one step. Repeat per GA account if we have several.

That's all. The next daily run (stacks:daily_enterprise_tasks) adds every GA4 property the account can see
as a site (Stacks admin → Dashboard → **Site Analytics**; name = GA display name) and backfills 13 months.
`rake site_analytics:discover` does the discovery on demand. Sites are never deleted automatically: uncheck
**Active** to stop syncing one, or rename it for how people will ask for it.

Optional override: set Heroku config `GOOGLE_ANALYTICS_SERVICE_ACCOUNT_JSON` to a different service account's
JSON key; it wins over the credentials account.

Client properties later: their admin adds the same service account email as Viewer; discovery picks them up.
