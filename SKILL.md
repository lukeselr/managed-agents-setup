---
name: managed-agents-setup
description: Zero-to-production Anthropic Managed Agents + Routines setup. Takes a non-technical business owner from zero to a running cloud agent with scheduled tasks. Pairs with server-setup — the server is the glue layer (webhooks + cron), not a third-party platform. User approves prompts, watches it happen.
---

# Managed Agents Setup Skill

> **Purpose**: Take a user from "I have an Anthropic account" to "I have a Managed Agent running on a schedule, triggerable by n8n webhook, with vault-backed MCP credentials."
>
> **Pairs with**: `server-setup` (for full-stack server infrastructure). This skill can run standalone OR extend a server-setup install.
>
> **Audience**: Non-technical owners in Selr AI workshops. They should never type a command, edit a file, or troubleshoot anything.
>
> **Execution model**: Driven by the `managed-agents-setup` agent (see `agents/managed-agents-setup.md`). The agent walks through each phase, using Playwright for browser steps and Bash for API/CLI calls. User only approves tool prompts.

---

## How to Use This Skill

Invoke via the `managed-agents-setup` agent:

```
Agent({
  description: "Set up Managed Agents + Routines",
  subagent_type: "managed-agents-setup",
  prompt: "Install Managed Agents for this user. Their Anthropic API key is already in keychain."
})
```

Or run phases manually by reading this file and executing the scripts.

---

## Architecture — What Gets Built

```
┌─────────────────────────────────────────────────────────────┐
│                   User's Mac (local)                        │
│  • ant CLI + Anthropic SDK (python + typescript)            │
│  • API key in keychain                                       │
│  • secrets.env with third-party tokens                       │
└──────────────┬──────────────────────────────────────────────┘
               │ creates + configures
               ▼
┌─────────────────────────────────────────────────────────────┐
│            Anthropic Platform (api.anthropic.com)           │
│  • Workspace (team-scoped billing + keys)                    │
│  • Agents (reusable configs: model + prompt + tools + MCP)   │
│  • Environments (container templates: packages + networking) │
│  • Vaults (encrypted MCP credentials, never hit sandbox)     │
│  • Sessions (running instances with durable event log)       │
└──────────────┬──────────────────────────────────────────────┘
               │ MCP connector calls (authed via vault)
               ▼
┌─────────────────────────────────────────────────────────────┐
│                 Third-party MCP Servers                      │
│  GHL • Supabase • Gmail • Calendar • ManyChat • Meta • etc.  │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│        Claude Code Routines (claude.ai/code/routines)       │
│  • Scheduled triggers (cron, 1hr min, UTC)                   │
│  • API triggers (OAT token → /fire endpoint)                 │
│  • Fires a full Claude Code session on an Anthropic VM       │
│  • Repo-scoped: sees .claude/ + .mcp.json committed in repo  │
└──────────────┬──────────────────────────────────────────────┘
               │ HTTP webhook (bidirectional)
               ▼
┌─────────────────────────────────────────────────────────────┐
│         Your Server (EC2 via server-setup) — GLUE LAYER      │
│  • Inbound webhooks: FastAPI on :8080 → /v1/sessions         │
│  • Cron jobs: sub-hourly triggers → /fire on routines        │
│  • Telegram bot: /command → run Managed Agent session        │
│  • Server agents (agents-cc) call managed-agents.sh helper   │
│  • NO third-party glue platforms — code-owned end to end     │
└─────────────────────────────────────────────────────────────┘
```

---

## Phase 0: Pre-Flight Checks

Verify the local environment and detect existing installs.

```bash
bash ~/.claude/skills/managed-agents-setup/scripts/preflight.sh
```

**Outputs JSON status**:
- `anthropic_key_present`: bool (checks `$ANTHROPIC_API_KEY` + keychain)
- `ant_cli_installed`: bool
- `python_sdk_installed`: bool
- `typescript_sdk_installed`: bool
- `server_setup_detected`: bool (looks for `~/agents-cc` on server via SSH)
- `secrets_env_path`: path or null
- `n8n_url`: url or null (from env)

If any required item missing, the script prints exact commands to fix.

---

## Phase 1: Anthropic Console Setup

Create workspace + API key via the Anthropic Console.

**Option A — Playwright driven (hands-free)**:
```
1. Open https://platform.claude.com/login
2. User authenticates (OAuth or email). Wait for dashboard.
3. Navigate to Settings > Workspaces. Create workspace named "AGENTS-<user>".
4. Settings > API Keys. Create key scoped to that workspace. Name it "managed-agents-key".
5. Copy the key value to clipboard, stash in Mac keychain:
   security add-generic-password -a "$USER" -s "anthropic-managed-agents" -w "sk-ant-..." -U
6. Click "Billing" > verify payment method (user approves).
```

**Option B — User provides key**:
```
security add-generic-password -a "$USER" -s "anthropic-managed-agents" -w "$KEY" -U
export ANTHROPIC_API_KEY=$(security find-generic-password -a "$USER" -s "anthropic-managed-agents" -w)
```

**Verify**:
```bash
curl -sS https://api.anthropic.com/v1/models \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" | jq '.data[0]'
```

---

## Phase 2: Local CLI + SDK Install

```bash
bash ~/.claude/skills/managed-agents-setup/scripts/install-cli.sh
```

Installs:
- `ant` CLI via Homebrew tap (`anthropics/tap/ant`)
- Python SDK: `pip3 install --user anthropic`
- TypeScript SDK: `npm install -g @anthropic-ai/sdk` (optional)
- Sets `ANTHROPIC_API_KEY` in shell profile if not already set

**Verify**:
```bash
ant --version
python3 -c "from anthropic import Anthropic; print(Anthropic().api_key[:10])"
```

---

## Phase 3: Vault Seeding

Push third-party credentials into Anthropic Vaults so MCP calls can authenticate.

```bash
python3 ~/.claude/skills/managed-agents-setup/scripts/vault-seeder.py \
  --secrets-env ~/agents-cc/shared/secrets.env \
  --vault-name "primary"
```

Reads `secrets.env`, matches known keys to MCP server URLs (see `references/mcp-servers-catalog.md`), creates a vault, and adds one credential per MCP server. Supports `static_bearer` (API keys/PATs) and `mcp_oauth` (OAuth refresh flow).

**Companion: `mcp-bridge.sh`** — mirrors your Claude Code MCP connections into the same vault so hosted agents get the same services your local Claude Code has. See `references/mcp-bridge.json` for the 30-MCP inventory and `scripts/mcp-bridge.sh` for the bridge script. Run after vault-seeder:
```bash
bash ~/.claude/skills/managed-agents-setup/scripts/mcp-bridge.sh \
  --vault "$(cat ~/.claude/managed-agents/vault-id.txt)" --category A
```

**Example mappings** (auto-detected by the script):
| Env var | MCP server URL | Auth type |
|---------|----------------|-----------|
| `GHL_API_KEY` | `https://mcp.gohighlevel.com` | static_bearer |
| `SUPABASE_SERVICE_KEY` | `https://mcp.supabase.com/{project}` | static_bearer |
| `META_ADS_TOKEN` | `https://mcp.meta.com/ads` | static_bearer |
| `GOOGLE_OAUTH_REFRESH` | Gmail / Calendar MCP | mcp_oauth |
| `MANYCHAT_API_KEY` | `https://mcp.manychat.com` | static_bearer |
| `COMPOSIO_API_KEY` | `https://backend.composio.dev/v3/mcp` | static_bearer — Rube/Composio "500+ apps" gateway |

**Rube (Composio) — the cheat code**: If the user adds `COMPOSIO_API_KEY` to `secrets.env`, the seeder wires up the Rube/Composio gateway MCP which exposes 500+ services (Gmail, Slack, Notion, GitHub, HubSpot, Stripe, Drive, Calendar, Shopify, Twitter, Linear, Airtable, etc.) through a single credential. Agents discover tools via `RUBE_SEARCH_TOOLS` and call them via `RUBE_EXECUTE_TOOL`. For interactive desktop use, `https://rube.app/mcp` (OAuth 2.1) is preferred — workshop attendees sign up at rube.app, click "authorize" per service they want, then plug their Composio API key into `secrets.env`. Free during beta; ~20k-100k free tool calls/mo on the Composio free tier. **Confirm pricing at rube.app/pricing before workshop rollout — paid plans launching post-beta.**

Vault ID is written to `~/.claude/managed-agents/vault-id.txt` for later phases.

---

## Phase 4: First Environment

Create a container template (packages + networking).

```bash
bash ~/.claude/skills/managed-agents-setup/scripts/create-environment.sh primary
```

Uses `references/environment-templates.json` with `primary` preset (basic Python + networking unrestricted). Other presets: `full-stack`, `locked-down`, `content-engine`.

**Env ID** is written to `~/.claude/managed-agents/env-id.txt`.

---

## Phase 5: First Agent

Create a reusable agent config referencing the environment + vault + MCP servers.

```bash
bash ~/.claude/skills/managed-agents-setup/scripts/create-agent.sh general
```

Uses `references/agent-templates.json`. Presets:
- `general` — Sonnet 4.6, bash/read/write/edit/web_fetch, no MCP
- **`rube-universal`** — Sonnet 4.6 + Rube MCP (`rube.app/mcp`, OAuth). 500+ services via one connection. **Recommended default for workshop attendees.**
- **`rube-headless`** — Sonnet 4.6 + Composio static-key MCP (`backend.composio.dev/v3/mcp`). Same 500+ services, no interactive OAuth. **For server cron and routines.**
- `ghl-sales` — Opus 4.7, GHL MCP, sales persona
- `content-creator` — Sonnet 4.6, Notion + Gmail MCP, content persona
- `ops-monitor` — Haiku 4.5, bash only, ops persona (cheap)
- `multi-agent-coordinator` — Opus 4.7, `callable_agents` (research preview only)

**Agent ID** is written to `~/.claude/managed-agents/agents/<preset>.txt`.

---

## Phase 6: First Session + Smoke Test

Start a session, send a message, stream the response.

```bash
python3 ~/.claude/skills/managed-agents-setup/scripts/run-session.py \
  --agent-id "$(cat ~/.claude/managed-agents/agents/general.txt)" \
  --env-id "$(cat ~/.claude/managed-agents/env-id.txt)" \
  --vault-id "$(cat ~/.claude/managed-agents/vault-id.txt)" \
  --message "List the files in your working directory. Reply with just the file list."
```

Streams SSE events, prints text blocks, exits on `session.status_idle`. Prints the session ID for follow-up.

---

## Phase 6.5: Safety Guardrails (MUST-DO)

Before running anything unattended, install the cost cap + kill switch. This is non-negotiable for any scheduled or production use.

### Set workspace spend cap

Browser-driven, via the Anthropic console:
```
Settings > Billing > Monthly spend limit > set to $50 (or your number)
```
When hit, Anthropic stops all new API calls. No surprise bill.

### Install kill switch

```bash
chmod +x ~/.claude/skills/managed-agents-setup/scripts/killswitch.sh
# Test (safe — just lists):
bash ~/.claude/skills/managed-agents-setup/scripts/killswitch.sh
```

**Three modes**:
- default: interrupts all running sessions (reversible)
- `--archive`: interrupts + archives all sessions (can't resume)
- `--nuke`: archives everything (sessions + agents + envs + vaults)

**Panic button on Telegram**: add a `/killswitch` command to the bot that runs this, so you can stop everything from your phone.

### Deploy daily cost monitor as a Routine

The `daily-cost-monitor.py` runs at 8am Brisbane, pushes usage + running sessions to Telegram, auto-triggers killswitch if daily estimate exceeds `DAILY_SPEND_CAP_USD` (default $20).

```bash
# Create it as a routine via the API
bash ~/.claude/skills/managed-agents-setup/scripts/create-routine.sh \
  --name "daily-cost-monitor" \
  --cron "0 22 * * *" \
  --prompt "Run ~/.claude/skills/managed-agents-setup/scripts/daily-cost-monitor.py" \
  --repo "https://github.com/YOUR/repo" \
  --env-id "$(cat ~/.claude/managed-agents/env-id.txt)"
```

Brisbane 8am = 22:00 UTC previous day. See `references/routines-cron-cheatsheet.md`.

---

## Phase 7: Routines (Scheduled Cloud Tasks)

Create a scheduled Claude Code routine at `claude.ai/code/routines`. **NOT Managed Agents** — this is the Claude Code subscription surface. Min 1hr interval, UTC cron.

**Option A — Web UI (easiest for non-tech users)**:
```
1. Open https://claude.ai/code/routines
2. Click "New routine"
3. Name: "daily-checkin"
4. Prompt: "Review yesterday's agent runs. Flag any failures. Reply with summary."
5. Schedule: daily at 9am (UI handles timezone conversion)
6. Repo: user's repo with .claude/ config
7. MCP connectors: toggle Gmail, Notion, etc.
8. Save. Then generate an OAT token for API-triggered fires (shown once).
```

**Option B — API (for power users + n8n glue)**:
```bash
bash ~/.claude/skills/managed-agents-setup/scripts/create-routine.sh \
  --name "daily-checkin" \
  --cron "0 23 * * *" \
  --prompt "Review yesterday's agent runs..." \
  --repo "https://github.com/user/repo" \
  --env-id "$(cat ~/.claude/managed-agents/env-id.txt)"
```

**Fire manually**:
```bash
bash ~/.claude/skills/managed-agents-setup/scripts/fire-routine.sh <trig_id>
```

**Routine → n8n**: inside the routine prompt, include `curl -X POST $N8N_WEBHOOK_URL -d '{...}'`. The cloud VM has curl preinstalled.

**Cron cheatsheet**: see `references/routines-cron-cheatsheet.md` (UTC conversion tables for AU/US/EU).

**Gotcha — `trig_` prefix**: The routine ID starts with `trig_...`, not `routine_...`. The URL path param is `routine_id` but the value is `trig_...`. Don't regex on `routine_`.

---

## Phase 8: Server as Glue Layer

Your server (installed by `server-setup`) IS the glue. No third-party automation platform. Three patterns — install whichever you need.

```bash
bash ~/.claude/skills/managed-agents-setup/scripts/install-server-glue.sh
```

**Pattern A — Inbound webhook receiver** (external services → Managed Agent session):
Tiny FastAPI app at `https://your-server:8080/hook/<name>`. Validates shared-secret header, fires a Managed Agent session, returns session URL. Lives at `~/agents-cc/webhook-server/` on the server, managed by systemd.

**Pattern B — Server cron → /fire routine** (sub-hourly scheduled fires):
Routines API has a 1hr minimum on its own cron. For anything faster (every 15 min, every 5 min), use server cron hitting the `/fire` endpoint:
```
*/15 * * * * ~/agents-cc/shared/scripts/fire-routine.sh trig_xxx "hourly sweep"
```

**Pattern C — Telegram bot trigger** (chat → agent session):
Existing `telegram-bot/bot.py` from server-setup gets a new command — `/ma <agent_name> <message>` — that fires a Managed Agent session and streams the result back as a Telegram message. Keeps you in control of which agent runs.

See `references/server-glue-patterns.md` for exact code for each.

**Why not n8n/Make/Zapier**: code-owned end to end. No vendor lock, no rate limits stacked on rate limits, no broken webhooks mid-execution. If you want to bolt a workflow platform on later, the server helpers are drop-in HTTP.

---

## Phase 9: Server Pairing (Optional)

If `server-setup` already ran and `~/agents-cc` exists on the server, wire the EC2 agents to hit Managed Agents.

```bash
bash ~/.claude/skills/managed-agents-setup/scripts/link-to-server.sh
```

Does:
- Copies `ANTHROPIC_API_KEY` to server's `~/agents-cc/shared/secrets.env`
- Adds helper function to `run-agent.sh`: `call_managed_agent <agent_name> <message>` that hits `/v1/sessions`
- Mirrors vault IDs + agent IDs to server env
- Optionally reroutes heavy agents (Brain, Research) through Managed Agents while keeping cheap/fast agents (Ops, Finance) on EC2

This lets you keep the EC2 server for local scripts + cron AND add Managed Agents for expensive long-running sessions. Best of both.

---

## Phase 10: Verification & Handoff

Run the full smoke test:

```bash
bash ~/.claude/skills/managed-agents-setup/scripts/smoke-test.sh
```

Checks:
- [ ] `ant --version` returns 1.x
- [ ] `ANTHROPIC_API_KEY` in shell + keychain
- [ ] Workspace reachable (`GET /v1/workspaces/me`)
- [ ] At least one agent exists (`GET /v1/agents`)
- [ ] At least one environment exists
- [ ] At least one vault with ≥1 credential
- [ ] Smoke session completes (create → send → `idle`)
- [ ] If routines configured: routine listed via RemoteTrigger
- [ ] If server-paired: `call_managed_agent` helper works on server
- [ ] If webhook receiver installed: `curl -X POST :8080/hook/test` returns session URL

Prints a handoff summary with all IDs + next steps.

---

## Cost Guardrails

See `references/cost-calculator.md`. Key numbers:

| Model | Input $/MTok | Output $/MTok | 1hr session w/ 50K in + 15K out |
|-------|--------------|---------------|--------------------------------|
| Haiku 4.5 | $1 | $5 | $0.205 |
| Sonnet 4.6 | $3 | $15 | $0.455 |
| Opus 4.7 | $5 | $25 | $0.705 |

Plus `$0.08/session-hour` runtime (only while running). Web search $10/1K. Prompt caching reads at 10% of input.

**Rule of thumb**: Running Opus 4.7 8hr/day = ~$17/month runtime + tokens. Budget $50-200/month for moderate use.

**Daily spend cap**: set via workspace billing. Create a cheap Haiku agent to email/Telegram a daily cost report.

---

## Troubleshooting

See `references/troubleshooting.md`. Most common:
- **400 bad beta header** → missing `anthropic-beta: managed-agents-2026-04-01`
- **401 unauthorized** → wrong key or key scoped to different workspace
- **Session stuck in `running`** → send `user.interrupt` event before delete
- **MCP tool fails with 401** → vault credential expired, rotate via `POST /vaults/{id}/credentials/{cid}`
- **Routine fires but errors** → check `anthropic-beta: experimental-cc-routine-2026-04-01` is set, not the Managed Agents header
- **File not in `files.list` after session idle** → 1-3s indexing lag, retry

---

## Handoff to User

After Phase 10 passes, show the user:

```
Your Managed Agents setup is live.

• API key: stashed in Mac keychain ("anthropic-managed-agents")
• Agent dashboard: https://platform.claude.com/settings/agents
• Routines: https://claude.ai/code/routines
• Server: ssh <YOUR_SERVER_USER>@<YOUR_SERVER_IP>
• Webhook: https://<SERVER_IP>:8080/hook/<name>  (if Pattern A installed)
• Cost dashboard: https://platform.claude.com/settings/usage

To trigger an agent from your laptop:
  python3 ~/.claude/managed-agents/run.py "<message>"

To trigger from n8n or an external app:
  POST to https://api.anthropic.com/v1/claude_code/routines/<trig_id>/fire
  Header: Authorization: Bearer <your OAT token>

Your OAT tokens and routine IDs are saved in ~/.claude/managed-agents/.
```

---

## Setup Checklist (for the driving agent)

- [ ] Phase 0 — Pre-flight passes
- [ ] Phase 1 — API key in keychain, workspace created
- [ ] Phase 2 — `ant` + SDKs installed
- [ ] Phase 3 — Vault created with ≥1 credential
- [ ] Phase 4 — Environment created
- [ ] Phase 5 — At least one agent created
- [ ] Phase 6 — Smoke session passes
- [ ] Phase 7 — At least one routine created (optional but recommended)
- [ ] Phase 8 — Server glue installed (optional: webhook receiver / cron fires / Telegram /ma command)
- [ ] Phase 9 — Server paired (if server-setup ran)
- [ ] Phase 10 — Smoke test passes, user shown handoff summary
