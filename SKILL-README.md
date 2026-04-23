# managed-agents-setup

Zero-to-production installer for **Anthropic Managed Agents + Claude Code Routines**, designed for non-technical business owners.

Takes a blank Mac to a running cloud agent with scheduled tasks, vault-backed credentials, and 500+ service integrations via Rube (Composio). Pairs with `server-setup` so your server becomes the glue layer (webhook + cron + Telegram), not a third-party platform.

## 30-second version

```bash
bash ~/.claude/skills/managed-agents-setup/scripts/install-everything.sh
```

Answer 3 questions. Done in ~10 minutes. You'll have: API key stored in Mac keychain, ant CLI, SDKs, vault with your tokens, first agent, first session tested.

## What's in here

### `scripts/` — executable
| Script | What it does |
|--------|--------------|
| `install-everything.sh` | Single-command TUI. Wraps every prereq + connector wizard. Start here. |
| `connector-wizard.sh` | Walks user through GHL/Gmail/Meta/Rube token capture |
| `preflight.sh` | Pre-flight check, JSON status report |
| `install-cli.sh` | Install ant CLI + Python/TS SDKs |
| `vault-seeder.py` | Read secrets.env, push into Anthropic vault |
| `mcp-bridge.sh` | Mirror Claude Code MCPs into vault (category A) |
| `create-environment.sh` | Create container template (packages + networking) |
| `create-agent.sh` | Create agent from preset |
| `run-session.py` | Start session, send message, stream response |
| `create-routine.sh` | Build scheduled routine (cron or one-shot) |
| `fire-routine.sh` | Manually fire routine via OAT token |
| `create-routines-repo.sh` | Bootstrap GitHub repo with `.claude/` config |
| `install-server-glue.sh` | Deploy webhook receiver + fire helpers to EC2 |
| `link-to-server.sh` | Wire EC2 agents-cc to Managed Agents |
| `promote-v2-to-managed-agents.sh` | Read server v2 CLAUDE.md personas, create MAs |
| `ec2-agent-health-monitor.sh` | Live agent monitor with Telegram alerts |
| `killswitch.sh` | Panic button, interrupt + archive sessions |
| `reset-managed-agents.sh` | Roll back everything this skill created |
| `daily-cost-monitor.py` | Deployed as Routine, alerts on spend overrun |
| `rotate.sh` | Rotate vault credentials when tokens expire |
| `telegram-commands-patch.sh` | Add `/ma`, `/killswitch`, `/cost` to Telegram bot |
| `share-log.sh` | Redact + upload install log for support |
| `install-log-lib.sh` | Shared logging helper (sourced by other scripts) |
| `smoke-test.sh` | End-to-end verification |

### `references/` — data + docs
| File | What it has |
|------|-------------|
| `agent-templates.json` | 9 general presets: general, rube-universal, rube-headless, ghl-sales, content-creator, ops-monitor, research-assistant, supabase-dba, multi-agent-coordinator |
| `business-outcome-presets.json` | 7 Aussie small-business presets (real estate, coach, trades, consultant, e-com, IG content, bookkeeper). The **workshop moat**. |
| `environment-templates.json` | 4 env presets (primary, full-stack, locked-down, content-engine) |
| `mcp-servers-catalog.md` | Remote MCP directory with Rube vs direct guidance |
| `mcp-bridge.json` | 30-MCP inventory classified A/B/C/D |
| `routines-cron-cheatsheet.md` | UTC ↔ Brisbane/US/EU conversion tables |
| `server-glue-patterns.md` | Three canonical server glue flows |
| `cost-calculator.md` | Pricing + 3 worked examples + guardrails |
| `troubleshooting.md` | Common errors + fixes |

### `agents/managed-agents-setup.md`
Driver agent that reads SKILL.md and walks the 10 phases.

## Key concepts

- **Vaults** store credentials. One per agent role recommended. Credentials never touch the sandbox.
- **Rube (Composio)** = one connection, 500+ services. Default for workshop attendees.
- **Routines** = Claude Code scheduled tasks, 1hr minimum. NOT Managed Agents.
- **Three schedulers exist** (Routines / Desktop / `/loop`) — don't conflate.

## Safety guardrails

- `killswitch.sh` — interrupt all running sessions in one command
- `reset-managed-agents.sh` — nuke everything the skill created
- Workspace spend cap — set at platform.claude.com/settings/billing
- `daily-cost-monitor.py` — deployed as Routine, pings Telegram on overrun
- `rotate.sh` — quick credential rotation when tokens expire

## Architecture

```
Mac: ant CLI + API key in keychain
   |
   v
Anthropic Platform: Agents + Environments + Vaults + Sessions
   |
   v (vault-authed MCP calls)
Third-party MCP servers (GHL, Supabase, Rube, etc.)

Claude Code Routines (claude.ai/code/routines)
   ^
   | (HTTP webhooks)
Your Server (EC2 via server-setup)
  - FastAPI webhook :8080
  - Cron -> /fire routines
  - Telegram bot -> /ma, /killswitch, /cost
```

## Audience

- **Author's stack**: reference integration with EC2 + Supabase + GHL + Obsidian
- **Workshop attendees**: `install-everything.sh` is the entry point, `rube-universal` is the default agent, business-outcome-presets are the selling point

Built 2026-04-23. See `SKILL.md` for full phase-by-phase installer guide.
