# Routines Cron Cheatsheet

Claude Code routines use **5-field UTC cron**. Minimum interval **1 hour**.

## Timezone Conversion (Local → UTC)

| Local time (AEST UTC+10) | UTC equivalent | Cron expression |
|---------------------------|----------------|-----------------|
| 6am Brisbane | 8pm previous day | `0 20 * * *` |
| 7am | 9pm prev | `0 21 * * *` |
| 8am | 10pm prev | `0 22 * * *` |
| 9am | 11pm prev | `0 23 * * *` |
| 10am | midnight | `0 0 * * *` |
| 12pm (noon) | 2am | `0 2 * * *` |
| 3pm | 5am | `0 5 * * *` |
| 6pm | 8am | `0 8 * * *` |
| 9pm | 11am | `0 11 * * *` |
| 11pm | 1pm | `0 13 * * *` |

For AEDT (daylight saving, UTC+11): subtract 11 hours instead of 10.

## Common Patterns

```
0 * * * *       — every hour on the hour
0 23 * * *      — daily at 9am Brisbane
0 23 * * 1-5    — weekdays only 9am Brisbane
0 0,12 * * *    — twice daily (midnight + noon UTC)
0 8 * * 1       — Mondays 6pm Brisbane
0 1 1 * *       — 1st of every month, 11am Brisbane
```

## Validating a Cron Expression

```bash
python3 -c "from croniter import croniter; croniter('0 23 * * *', return_type=str)"
```
Or use https://crontab.guru/ (UTC only — don't trust the local-time preview).

## Minimum Interval Rule

**1 hour minimum.** `*/30 * * * *` will be rejected with `400 invalid_cron_expression`.

Workarounds for sub-hourly:
- **`/loop 5m`** inside a CLI session (local-only, dies with session).
- **Desktop scheduled tasks** (Desktop app only, local machine).
- **n8n Schedule Trigger** every N minutes → HTTP Request to `/fire`. Bypasses cron minimum.

## One-Shot Scheduled Runs

Instead of `cron_expression`, use `run_once_at` (RFC3339 UTC, future):

```json
{"run_once_at": "2026-05-01T08:00:00Z"}
```

Auto-disables after firing.

## Gotchas

- **All fields in UTC.** No timezone field. Brisbane user saying "9am daily" means `0 23 * * *`, NOT `0 9 * * *`.
- **No seconds field.** 5-field cron only.
- **Stagger** — routines get a deterministic per-id offset, so `0 * * * *` across many routines doesn't slam the backend at :00.
- **Schedule changes** require editing via `/schedule update` or web UI. API partial updates supported.
- **Paused routines** still accept `/fire` calls but return `400` until resumed.
