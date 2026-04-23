# Troubleshooting — Managed Agents + Routines

## Managed Agents (Platform API)

### `400 Bad Request: missing beta header`
Every request to `/v1/agents`, `/v1/environments`, `/v1/sessions`, `/v1/vaults`, `/v1/sessions/*/events` needs:
```
anthropic-beta: managed-agents-2026-04-01
```

### `401 Unauthorized`
- Wrong API key. Verify: `echo $ANTHROPIC_API_KEY | cut -c1-10` should start with `sk-ant-`.
- Key scoped to different workspace. Generate a new key in the correct workspace.

### `403 Forbidden`
- Your workspace doesn't have Managed Agents enabled. Check Billing + request beta access at https://platform.claude.com/.

### `409 Conflict: credential for this mcp_server_url already exists`
One active credential per `mcp_server_url` per vault. Archive the old one first:
```bash
curl -X POST "https://api.anthropic.com/v1/vaults/$VAULT_ID/credentials/$CRED_ID/archive" ...
```

### `Session stuck in running`
Cannot delete a running session directly. Interrupt first:
```bash
curl -X POST "https://api.anthropic.com/v1/sessions/$ID/events" \
  -d '{"events":[{"type":"user.interrupt"}]}'
# Wait ~2s, then:
curl -X DELETE "https://api.anthropic.com/v1/sessions/$ID"
```

### `MCP tool returns 401`
Vault credential expired. Rotate:
```bash
curl -X POST "https://api.anthropic.com/v1/vaults/$VAULT/credentials/$CRED" \
  -d '{"auth":{"type":"static_bearer","token":"NEW_TOKEN","mcp_server_url":"SAME"}}'
```
Credentials re-resolve periodically in running sessions — rotation propagates without restart.

### `File not found in files.list after session idle`
1-3 second indexing lag. Retry. If still missing, file wasn't actually written.

### `Stream events arrive batched, not streamed`
Open the stream BEFORE sending the first `user.message`, or open them concurrently. Opening the stream AFTER sending causes batching.

### Rate limits
Create endpoints: 60 req/min. Read: 600 req/min. Exceed → `429 rate_limit_error` with `Retry-After`. Tier-based org limits apply on top.

## Routines

### `400 invalid_request_error: missing beta header`
Routine fires need:
```
anthropic-beta: experimental-cc-routine-2026-04-01
```
This is DIFFERENT from the Managed Agents beta header. Don't mix them.

### `400 invalid_cron_expression`
- 5-field cron required. No seconds, no `L`/`#` extensions.
- Minimum 1-hour interval. `*/30 * * * *` is rejected.
- UTC only. No timezone field.

### `400 routine is paused`
Unpause at `claude.ai/code/routines`.

### `401 Unauthorized` on /fire
- OAT token invalid or regenerated. Tokens are shown once — fetch a new one and update `ROUTINE_OAT_TOKEN`.
- Token scoped to different routine. Each routine has its own.

### `404 Not Found` on /fire
- `trig_id` wrong. **ID starts with `trig_`, not `routine_`.** Don't build regex on `routine_`.
- Routine deleted. Recreate at web UI.

### `429 rate_limit_error`
- Hit daily cap for your plan. Check `claude.ai/settings/usage`. Respect `Retry-After` header.
- Per-routine + per-account hourly caps during preview for GitHub-triggered routines.

### Routine fires but nothing happens
1. Check the session URL from the `/fire` response — does the session show up at `claude.ai/code/sessions`?
2. Session might've crashed at startup. Setup script failure → non-zero exit → session fails. Append `|| true` to optional installs.
3. Repo-level `.claude/` missing — user-scope config does NOT carry over to the cloud VM.

### MCP connector name rejected
Name regex is `[a-zA-Z0-9_-]` only. `claude.ai Gmail` fails (space + dot). Use `Gmail` or `claude-ai-Gmail`.

## Server Glue (FastAPI webhook receiver)

### `/hook/<name>` returns 404
`hooks.json` on the server doesn't have that name, or webhook-server wasn't restarted after edit:
```bash
ssh ubuntu@SERVER 'systemctl --user restart webhook-server'
```

### `/hook/<name>` returns 401
`X-Webhook-Secret` header missing or wrong. Fetch current value:
```bash
ssh ubuntu@SERVER 'grep WEBHOOK_SECRET ~/agents-cc/shared/secrets.env'
```

### Webhook returns 500
Check `journalctl --user -u webhook-server -n 50` on the server. Most common cause: `ANTHROPIC_API_KEY` missing or stale.

### Sub-hourly schedule needs to fire a routine
Use server cron hitting `fire-routine.sh`, not the Routines cron (which has a 1-hour minimum). Example:
```cron
*/10 * * * * ~/agents-cc/shared/scripts/fire-routine.sh trig_xxx "cron sweep"
```

## Local SDK / CLI

### `ant --version` says "command not found"
`brew install anthropics/tap/ant` then `xattr -d com.apple.quarantine "$(brew --prefix)/bin/ant"`.

### Python SDK can't find beta methods (`client.beta.agents`)
Upgrade: `pip3 install --user --upgrade anthropic`. Minimum version with Managed Agents support is 0.50.x.

### TypeScript SDK type errors
Upgrade: `npm install @anthropic-ai/sdk@latest`.

## Where to get help

- Anthropic Discord: https://www.anthropic.com/community
- Platform status: https://status.anthropic.com
- API docs: https://platform.claude.com/docs
- Routines docs: https://code.claude.com/docs/en/routines
