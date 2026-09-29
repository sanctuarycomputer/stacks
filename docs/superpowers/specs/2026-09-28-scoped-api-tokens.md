# Scoped API tokens for the MCP and API write surfaces

**Verdict:** anyone holding the read key can no longer write, once Stacksbot is moved to its own write token and
`STACKS_LEGACY_KEY_WRITE=off` is set. Until then nothing changes for existing callers.

## Why

Roadmap Phase 7 says the read MCP (`/api/mcp`) stays read-only and writes go through a separate surface with a
scoped token model. `/api/mcp/write` existed, but it accepted the same `X-Api-Key` as the read surface, so every
read-key holder could also write.

## What

- **`ApiToken`** (new table `api_tokens`): name, SHA-256 digest of the token (never the plaintext), a 12-character
  display prefix, scopes, created_by, last_used_at, revoked_at, expires_at.
- **Scopes** (least privilege):
  - `mcp:read`: the read MCP.
  - `mcp:write:resourcing`: assignments, placeholders, recurring assignments.
  - `mcp:write:projects`: create and archive tentative projects.
  - `mcp:write:trackers`: project trackers, workstreams, rates, roles, completion.
  - `api:write:projections`: `/api/v1/projected_assignments`.
- **Tool to scope map:** `Mcp::WriteServer::TOOL_SCOPES`. A test fails if a write tool is added without a scope. A
  token sees and can call only the tools its scopes allow; other tools are "not found".
- **Admin page** (Admin > API Tokens, admins only, never leads):
  - Mint a token. The plaintext is shown once, rendered rather than redirected, with `Cache-Control: no-store`, so
    it never enters a cookie, flash or log.
  - Revoke a token.
- **The legacy shared key:**
  - It keeps read access permanently.
  - It keeps write access only while `STACKS_LEGACY_KEY_WRITE` is not `off`. That is a Heroku config change, not a
    deploy.

## Rollout

1. Merge and deploy this PR. **MIGRATION** `20260929120000_create_api_tokens`: run `heroku run rails db:migrate`
   right after the release. Until the table exists, tokens are refused and the legacy key works exactly as before.
   No crash, no 500.
2. An admin mints "Stacksbot write" with `mcp:write:resourcing`, `mcp:write:projects`, `mcp:write:trackers` and
   `api:write:projections`. It goes into Stacksbot's SOPS as `STACKS_MCP_WRITE_TOKEN` (the companion Stacksbot PR).
3. Once Stacksbot runs on its token (the Stacks log shows `as token "Stacksbot write" (stk_…)` on
   `/api/mcp/write`), set `heroku config:set STACKS_LEGACY_KEY_WRITE=off`.
4. Rollback for step 3: `heroku config:unset STACKS_LEGACY_KEY_WRITE`.

## Adversarial review

| Risk | Answer |
|---|---|
| Plaintext stored | No. Only the SHA-256 digest is stored; the token has 256 random bits, so a slow hash adds nothing. |
| Timing attacks | Tokens are looked up by digest (an attacker only learns the timing of their own hash) and then secure_compare'd. The legacy key uses secure_compare. |
| Revocation lag | None. Every request reads `revoked_at` and `expires_at` from the row, with no cache. Tested: revoke, then the next request gets 403. |
| Leak in Rails logs | Rails never logs headers. Mint params are filtered (`token`, `api_key`, `secret`, `token_digest`). Log lines name a token only by name and prefix. |
| **Leak to Sentry (found here, pre-existing)** | Sentry 4.3 reports every `HTTP_*` header with each error and sampled trace (50% of requests). The legacy key has been going to sentry.io. The new `ApiKeyVault` middleware moves the key out of the header slot before the app runs; Sentry reads the same env hash, so it never sees the key. Tested through the real stack. **Consider rotating the legacy key** once Stacksbot is on its token. |
| Leads minting tokens | Blocked. `AdminAuthorization` gives ApiToken admins only, above the blanket lead grant. The hand-written `create` authorizes explicitly, because ActiveAdmin only authorizes inside `build_resource`. A test caught this hole. |
| Fail-open build | `Mcp::WriteServer.build` requires `scopes:`; a forgotten argument raises instead of exposing every tool. |
| Deploy before migration | `ApiToken.available?` checks the table exists. Before it does, tokens are refused and the legacy key behaves as today. Tested. |
| Read token calls a write tool | 403 at the controller: a read token holds no write scope. Tested. |

## The older REST write endpoints

These take the same scopes and follow the same deprecation switch, so the read key can't write through them
either:
- `POST /api/project_trackers` and the workstreams and rates routes need `mcp:write:trackers`.
- `POST /api/recurring_assignments` needs `mcp:write:resourcing`.

Stacksbot doesn't call any of them.

**Still on the legacy key, flagged:** `POST /api/contacts` writes contacts and has an unknown external caller, so
it is untouched here. Give it its own scope once the caller is known. The read endpoints (contributors,
project_trackers#index, contacts#index) stay on the legacy key.
