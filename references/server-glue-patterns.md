# Server Glue Patterns — Three Canonical Flows

Your server (`~/agents-cc` installed by `server-setup`) is the glue layer. Three patterns cover everything a workflow platform would do.

## Pattern A — Inbound Webhook Receiver

External service POSTs to your server → server fires a Managed Agent session.

**Install**: `bash scripts/install-server-glue.sh`

**Configure a hook** — edit `~/agents-cc/webhook-server/hooks.json` on the server:
```json
{
  "new-lead": {
    "agent_id": "agent_...",
    "env_id": "env_...",
    "vault_id": "vlt_..."
  },
  "support-ticket": {
    "agent_id": "agent_support_...",
    "env_id": "env_..."
  }
}
```

**Fire it**:
```bash
curl -X POST https://YOUR_SERVER:8080/hook/new-lead \
  -H "X-Webhook-Secret: $WEBHOOK_SECRET" \
  -d '{"name": "Jane Doe", "email": "jane@example.com"}'
```

Response:
```json
{"session_id": "ses_...", "url": "https://platform.claude.com/sessions/ses_..."}
```

**Common upstream sources**: Stripe/GHL/ManyChat webhooks, form submissions, IoT events, cron on other servers.

---

## Pattern B — Server Cron Fires Routines

Routines API has a 1-hour minimum on its own cron. For sub-hourly work, server cron hits the `/fire` endpoint.

**Add to crontab** (`~/agents-cc/crontab.txt` on the server):
```cron
# Every 15 min — quick sweep routine
*/15 * * * * ~/agents-cc/shared/scripts/fire-routine.sh trig_quick_sweep "cron sweep"

# Every 5 min during business hours — lead monitor
*/5 9-17 * * 1-5 ~/agents-cc/shared/scripts/fire-routine.sh trig_lead_monitor "biz-hours sweep"
```

Install: `crontab ~/agents-cc/crontab.txt`

**`fire-routine.sh` on server** — push from this skill to the server:
```bash
scp ~/.claude/skills/managed-agents-setup/scripts/fire-routine.sh <YOUR_SERVER_USER>@<YOUR_SERVER_IP>:~/agents-cc/shared/scripts/
ssh <YOUR_SERVER_USER>@<YOUR_SERVER_IP> 'chmod +x ~/agents-cc/shared/scripts/fire-routine.sh'
```

The script reads `ROUTINE_OAT_TOKEN` from `~/agents-cc/shared/secrets.env`. Store it there once, all cron jobs use it.

---

## Pattern C — Telegram Bot → Managed Agent Session

Existing `~/agents-cc/telegram-bot/bot.py` (from server-setup) already handles `/<agent_name> <message>` for local EC2 agents. Add `/ma <preset> <message>` for Managed Agent sessions.

**Patch bot.py on the server** — add this handler block:
```python
# Inside handle_command(), after existing agent-name dispatch:
if cmd == "ma":
    parts = message.split(maxsplit=1)
    if len(parts) < 2:
        send_message(chat_id, "Usage: /ma <preset> <message>")
        return
    preset, ma_msg = parts
    agent_id_path = os.path.expanduser(f"~/agents-cc/shared/managed-agents/agents/{preset}.txt")
    env_id_path = os.path.expanduser("~/agents-cc/shared/managed-agents/env-id.txt")
    if not os.path.exists(agent_id_path) or not os.path.exists(env_id_path):
        send_message(chat_id, f"Preset {preset} not configured. Run managed-agents-setup link-to-server.")
        return
    agent_id = open(agent_id_path).read().strip()
    env_id = open(env_id_path).read().strip()
    send_message(chat_id, f"Dispatching {preset} via Managed Agents...")
    try:
        result = subprocess.run(
            [os.path.expanduser("~/agents-cc/shared/scripts/managed-agents.sh"),
             agent_id, env_id, ma_msg],
            capture_output=True, text=True, timeout=30,
        )
        send_message(chat_id, f"Managed Agent:\n{result.stdout}")
    except subprocess.TimeoutExpired:
        send_message(chat_id, "Session create timed out")
    return
```

Then restart: `systemctl --user restart telegram-bot`.

**Usage on phone**: `/ma general What's the server disk usage?`

---

## Pattern Summary

| Use case | Pattern | Latency | Cost |
|----------|---------|---------|------|
| Stripe webhook → agent | A | <500ms | 1 session |
| Every 15 min cron → routine | B | instant fire | subscription pool |
| Boss on phone wants report | C | <3s | 1 session |
| Multi-step workflow | Managed Agent itself (with custom tools) | | 1 session |

**Anti-pattern**: Don't chain 3rd-party workflow platforms. If a flow starts at "external webhook" and ends at "agent does work", one of Patterns A-C handles it end-to-end. Code-owned.

---

## Security Notes

- **WEBHOOK_SECRET**: rotate via `echo "export WEBHOOK_SECRET=NEW" >> ~/agents-cc/shared/secrets.env && systemctl --user restart webhook-server`. Update all upstream callers.
- **HTTPS**: terminate TLS via Caddy/nginx in front of port 8080, OR run behind Tailscale so only authorized machines hit it (recommended default).
- **Rate limiting**: FastAPI default has none. Add [slowapi](https://pypi.org/project/slowapi/) if exposing to the public internet.
- **OAT tokens**: `ROUTINE_OAT_TOKEN` lives only in `secrets.env`. Never commit. `.gitignore` on the server already covers it.
