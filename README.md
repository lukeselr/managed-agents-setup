# managed-agents-setup

**Zero-to-production Anthropic Managed Agents + Routines, installed with one command.**
Built for non-technical business owners at Selr AI workshops — turns a fresh laptop into a running cloud agent (real estate, coach DM, tradie quote triage, ecom ops, etc.) in under 30 minutes.

---

## Quickstart

```bash
curl -fsSL https://raw.githubusercontent.com/lukeselr/managed-agents-setup/main/install.sh | bash
```

That's it. The installer will:

1. Clone the skill into `~/.claude/skills/managed-agents-setup/`
2. Check prerequisites (git, Anthropic API key, Homebrew)
3. Install the `ant` CLI + Python SDK
4. Seed your Anthropic vault with MCP credentials
5. Let you pick a **business-outcome preset** (see below)
6. Create a live Managed Agent with a scheduled Routine
7. Print the session URL + cost cap + kill-switch command

If you re-run the install, it safely updates in place. Idempotent.

---

## What you get

| | |
|---|---|
| **24 scripts** | preflight, install-cli, create-agent, create-routine, vault-seeder, kill-switch, cost monitor, mcp-bridge, smoke-test, and 15 more |
| **9 references** | agent templates, env templates, MCP bridge map, MCP catalog, cron cheatsheet, cost calculator, server glue patterns, business presets, troubleshooting |
| **7 business-outcome presets** | real-estate-agent, coach-ig-dm, trades-quote-triage, consultant-proposal-assist, ecommerce-ops, content-ig-daily, plus a blank template |
| **Rube/Composio integration** | one OAuth gives your agent Slack, HubSpot, Gmail, Google Drive, Stripe, Notion, Shopify, LinkedIn, YouTube, Telegram, Make, and 490+ more apps |
| **Daily cost monitor** | cron job that pings you if spend exceeds your cap |
| **Kill-switch** | one command pauses every running agent + routine |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                  Your Laptop (this installer)                │
│  • ant CLI, Python SDK, Anthropic key in keychain            │
│  • Vaults seeded with MCP creds                              │
└──────────────┬───────────────────────────────────────────────┘
               │
               ▼
┌──────────────────────────────────────────────────────────────┐
│        Anthropic Managed Agents (cloud VM per session)       │
│  • Stateless or persistent — you choose per agent            │
│  • MCP servers auto-loaded from vault                        │
│  • Web search, computer use, file system all built-in        │
└──────────────┬───────────────────────────────────────────────┘
               │ cron or API trigger
               ▼
┌──────────────────────────────────────────────────────────────┐
│         Claude Code Routines (claude.ai/code/routines)       │
│  • Scheduled triggers (cron, 1hr min, UTC)                   │
│  • API triggers (OAT token → /fire endpoint)                 │
└──────────────┬───────────────────────────────────────────────┘
               │ HTTP webhook (bidirectional, optional)
               ▼
┌──────────────────────────────────────────────────────────────┐
│         Your Server (EC2 / any VPS) — optional glue          │
│  • Inbound webhooks: FastAPI on :8080 → /v1/sessions         │
│  • Cron jobs: sub-hourly triggers → /fire on routines        │
│  • Telegram bot: /command → run Managed Agent session        │
│  • No third-party glue platforms — code-owned end to end     │
└──────────────────────────────────────────────────────────────┘
```

---

## Requirements

- **macOS** (Linux is untested but may work)
- **Homebrew** (installer will offer to install it)
- **git + bash** (preinstalled on macOS)
- **Anthropic API key** — get one at https://console.anthropic.com (the installer can walk you through this)
- **Credit on the Anthropic account** — expect **~$20–$50/month** for one always-on agent doing several sessions per day

Optional:
- A VPS (EC2, DigitalOcean, Hetzner) if you want the server glue layer for sub-hourly cron + Telegram control.

---

## Cost warnings — read before you run anything

- **Managed Agents are billed per session at the Claude API rate.** A single Opus session can cost \$0.50–\$5 depending on how long it runs and how many tools it uses.
- **Routines run automatically**. If you set a routine to fire every hour with Opus + heavy tool use, you can quietly spend \$10+ per day.
- The installer will ask you for a **daily cost cap** (default: \$5/day). The `scripts/daily-cost-monitor.py` cron job will alert you if you exceed it.
- **Kill switch**: `bash ~/.claude/skills/managed-agents-setup/scripts/killswitch.sh` pauses every agent + routine in your Anthropic workspace. Memorise this command.

**If you're unsure, start with Haiku models and a \$2/day cap.** You can raise it later.

---

## After install — what next?

The installer prints exact next steps. Typical flow:

1. **Pick a preset** (e.g. `coach-ig-dm`) → creates a running agent
2. **Connect your apps via Rube** → one OAuth click covers Gmail/Slack/Notion/Stripe/etc.
3. **Schedule a routine** → cron (e.g. every weekday 9am, or every 30 mins during business hours)
4. **Watch it run** → session URLs stream to your terminal; results optionally DM you on Telegram
5. **Tune the system prompt** → `scripts/create-agent.sh` reads `references/agent-templates.json` — edit + re-run

Full phase-by-phase walkthrough: see [SKILL.md](SKILL.md).

---

## Troubleshooting

Something broke? Run:
```bash
bash ~/.claude/skills/managed-agents-setup/scripts/share-log.sh
```

It uploads a redacted log gist (strips API keys, tokens, personal paths) and gives you a short ID you can share for support. See [references/troubleshooting.md](references/troubleshooting.md) for the common failure modes.

---

## Built for workshops

This is the skill we run live at **Selr AI** workshops. Attendees bring a laptop, we bring the installer, and by lunch everyone has a working cloud agent tuned to their actual business.

If you want to join one (or bring it into your team), see: **https://selrai.com.au**

---

## License

MIT — see [LICENSE](LICENSE).

Copyright © 2026 Luke Heka / Selr AI.

---

## Maintainer

- GitHub: [@lukeselr](https://github.com/lukeselr)
- Issues: [lukeselr/managed-agents-setup/issues](https://github.com/lukeselr/managed-agents-setup/issues)
- Instagram: [@lukeselr](https://instagram.com/lukeselr)
