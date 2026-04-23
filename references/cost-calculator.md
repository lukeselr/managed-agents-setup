# Cost Calculator — Managed Agents + Routines

## Managed Agents (Platform API)

### Token Pricing

| Model | Input $/MTok | Output $/MTok | Cache write (5m) | Cache read |
|-------|--------------|---------------|------------------|------------|
| Haiku 4.5 | $1 | $5 | 1.25x input | 0.1x input |
| Sonnet 4.6 | $3 | $15 | 1.25x input | 0.1x input |
| Opus 4.6 | $5 | $25 | 1.25x input | 0.1x input |
| Opus 4.7 | $5 | $25 | 1.25x input | 0.1x input |

### Runtime

**$0.08 per session-hour**, metered to the millisecond, ONLY while status is `running`. Idle / rescheduling / terminated do not accrue.

### Web Search

**$10 per 1,000 searches** on top of tokens. Budget this tight — research-heavy agents can easily rack up $10s/day.

### Worked Examples

**Example 1 — Light daily task (Sonnet 4.6, 15 min/day, low tokens)**:
- 15 min runtime × 30 days = 7.5 session-hours × $0.08 = **$0.60**
- 5K input + 2K output per run × 30 = 150K in + 60K out × $3/M + $15/M = **$1.35**
- Total: **~$2/month**

**Example 2 — Moderate research (Opus 4.7, 1hr/day, mid tokens)**:
- 30 session-hours × $0.08 = **$2.40**
- 50K in + 15K out per run × 30 = 1.5M in + 450K out × $5/M + $25/M = **$18.75**
- Plus 100 web searches × $0.01 = **$1**
- Total: **~$22/month**

**Example 3 — Heavy workload (Opus 4.7, 8hr/day)**:
- 240 session-hours × $0.08 = **$19.20**
- 500K in + 150K out per run × 30 = 15M in + 4.5M out × $5/M + $25/M = **$187.50**
- Total: **~$210/month**

## Routines (Claude Code Subscription)

**Zero extra compute charge.** Draws down Claude Code subscription usage (same pool as interactive sessions).

### Per-Plan Daily Routine Run Caps (preview, changes)

| Plan | Approx daily runs |
|------|-------------------|
| Pro | ~5-10/day |
| Max | ~20-25/day |
| Team | higher |
| Enterprise | custom |

**Over cap** → `429 rate_limit_error` with `Retry-After`. Orgs with Extra Usage enabled continue on metered overage.

## What IS NOT Available on Managed Agents

- ❌ Batch API (no 50% discount for batched requests)
- ❌ Fast mode (premium pricing variant)
- ❌ Data residency multiplier
- ❌ Long context premium
- ❌ Bedrock / Vertex / Foundry (first-party Claude API only)
- ❌ Claude Max / Pro subscription auth (API key only)

## Cost Guardrails

### Set a spend cap
Go to https://platform.claude.com/settings/usage → Billing → Monthly spend limit.

### Cheap cost-reporter agent
Create a Haiku 4.5 agent that runs daily, pulls the last 24h of usage via the Admin API, and Telegrams/emails a summary:

```
Prompt: "Check yesterday's usage via /v1/usage_report. If total > $5, send Telegram alert."
Schedule: daily at 9am
Model: claude-haiku-4-5
Expected cost: ~$0.10/day
```

### Archive idle agents + sessions
Sessions in `idle` status do not accrue runtime — but they hold resources. Archive:
```bash
curl -X POST "https://api.anthropic.com/v1/sessions/$ID/archive" -H ...
```

### Prefer cache
Agents re-reading the same files benefit hugely from prompt caching (reads at 10% of input rate). Design system prompts + tool definitions to be cache-friendly.

### Kill stuck sessions
Check `/v1/sessions?status=running`. If any are stuck beyond expected duration, send `user.interrupt` then archive.
