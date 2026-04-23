#!/usr/bin/env bash
# telegram-commands-patch.sh — Deploys /ma, /killswitch, /cost commands to the server's Telegram bot.
# Builds on your existing telegram-bot-v2.py (same allowlist, same auth).
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/clawd-key.pem}"
SSH_HOST="${SSH_HOST:-<YOUR_SERVER_USER>@<YOUR_SERVER_IP>}"
SSH_CMD="ssh -o BatchMode=yes -i $SSH_KEY $SSH_HOST"

TMP_EXT=$(mktemp /tmp/ma-commands-ext.py.XXXXXX)
cat > "$TMP_EXT" <<'PY'
"""
ma_commands.py — Managed Agents commands for telegram-bot-v2.
Imported by bot.py. Adds /ma, /killswitch, /killall, /cost, /agents.
"""
import json
import os
import subprocess
from pathlib import Path

STATE_DIR = Path.home() / ".claude" / "managed-agents"
if not STATE_DIR.exists():
    STATE_DIR = Path.home() / "agents-cc" / "shared" / "managed-agents"


def handle_ma(parts, chat_id, send_message):
    if len(parts) < 2:
        send_message(chat_id, "Usage: /ma <preset> <message>")
        return
    preset = parts[0]
    msg = parts[1]
    agent_file = STATE_DIR / "agents" / f"{preset}.txt"
    env_file = STATE_DIR / "env-id.txt"
    if not agent_file.exists():
        send_message(chat_id, f"Preset '{preset}' not configured.")
        return
    if not env_file.exists():
        send_message(chat_id, "No environment configured.")
        return
    script = Path.home() / "agents-cc" / "shared" / "scripts" / "managed-agents.sh"
    if not script.exists():
        send_message(chat_id, "managed-agents.sh missing. Run link-to-server.sh.")
        return
    send_message(chat_id, f"Dispatching {preset}...")
    try:
        result = subprocess.run(
            [str(script), agent_file.read_text().strip(), env_file.read_text().strip(), msg],
            capture_output=True, text=True, timeout=30,
        )
        output = (result.stdout or result.stderr)[:3500]
        send_message(chat_id, f"*{preset}*\n```\n{output}\n```")
    except subprocess.TimeoutExpired:
        send_message(chat_id, "Session create timed out")


def _ma_headers():
    import os
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return None
    return {
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": "managed-agents-2026-04-01",
    }


def handle_killswitch(chat_id, send_message):
    import urllib.request
    h = _ma_headers()
    if not h:
        send_message(chat_id, "ANTHROPIC_API_KEY not set on server.")
        return
    try:
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/sessions?status=running", headers=h)
        data = json.loads(urllib.request.urlopen(req, timeout=10).read())
        sessions = data.get("data", [])
        if not sessions:
            send_message(chat_id, "No running sessions.")
            return
        lines = [f"{len(sessions)} running session(s):"]
        for s in sessions[:10]:
            lines.append(f"  `{s['id']}` {s.get('title', '?')}")
        lines.append("\nSend /killall to interrupt every running session")
        send_message(chat_id, "\n".join(lines))
    except Exception as e:
        send_message(chat_id, f"Killswitch query failed: {e}")


def handle_killall(chat_id, send_message):
    import urllib.request
    h = _ma_headers()
    if not h:
        send_message(chat_id, "ANTHROPIC_API_KEY not set.")
        return
    try:
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/sessions?status=running", headers=h)
        sessions = json.loads(urllib.request.urlopen(req, timeout=10).read()).get("data", [])
        killed = 0
        for s in sessions:
            body = json.dumps({"events": [{"type": "user.interrupt"}]}).encode()
            ir = urllib.request.Request(
                f"https://api.anthropic.com/v1/sessions/{s['id']}/events",
                data=body, headers={**h, "content-type": "application/json"},
            )
            try:
                urllib.request.urlopen(ir, timeout=5)
                killed += 1
            except Exception:
                pass
        send_message(chat_id, f"Killed {killed}/{len(sessions)} running sessions.")
    except Exception as e:
        send_message(chat_id, f"Killall failed: {e}")


def handle_cost(chat_id, send_message):
    import urllib.request
    from datetime import datetime, timezone
    h = _ma_headers()
    if not h:
        send_message(chat_id, "ANTHROPIC_API_KEY not set.")
        return
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    try:
        req = urllib.request.Request("https://api.anthropic.com/v1/sessions?limit=100", headers=h)
        data = json.loads(urllib.request.urlopen(req, timeout=10).read())
        todays = [s for s in data.get("data", []) if s.get("created_at", "").startswith(today)]
        running = [s for s in data.get("data", []) if s.get("status") == "running"]
        est = len(todays) * 0.15
        send_message(chat_id, f"*Today:* {today}\nSessions: {len(todays)}\nRunning: {len(running)}\nEst spend: ${est:.2f}")
    except Exception as e:
        send_message(chat_id, f"Cost query failed: {e}")


def handle_agents(chat_id, send_message):
    agents_dir = STATE_DIR / "agents"
    if not agents_dir.exists():
        send_message(chat_id, "No agents configured.")
        return
    entries = []
    for f in sorted(agents_dir.glob("*.txt")):
        entries.append(f"  {f.stem} -> `{f.read_text().strip()}`")
    env_id = (STATE_DIR / "env-id.txt").read_text().strip() if (STATE_DIR / "env-id.txt").exists() else "none"
    send_message(chat_id, f"*Agents* (env={env_id}):\n" + "\n".join(entries))


def dispatch(cmd, parts, chat_id, send_message):
    if cmd == "ma":
        handle_ma(parts, chat_id, send_message); return True
    if cmd == "killswitch":
        handle_killswitch(chat_id, send_message); return True
    if cmd == "killall":
        handle_killall(chat_id, send_message); return True
    if cmd == "cost":
        handle_cost(chat_id, send_message); return True
    if cmd == "agents":
        handle_agents(chat_id, send_message); return True
    return False
PY

echo "[telegram-patch] Copying extension to server..."
scp -o BatchMode=yes -i "$SSH_KEY" "$TMP_EXT" "$SSH_HOST:/home/ubuntu/agents-cc/shared/ma_commands.py"
rm -f "$TMP_EXT"

echo "[telegram-patch] Locating bot.py and patching..."
$SSH_CMD 'BOT_PY=$(find ~/agents-cc ~/archive 2>/dev/null -name "telegram-bot-v2.py" -o -name "bot.py" | head -1)
if [ -z "$BOT_PY" ]; then
  echo "[fatal] No telegram bot python file found"
  exit 1
fi
echo "[patch] Target: $BOT_PY"
cp "$BOT_PY" "$BOT_PY.bak-$(date +%s)"

python3 <<PY
import pathlib, re
p = pathlib.Path("$BOT_PY")
src = p.read_text()
if "ma_commands" in src:
    print("[skip] Already patched")
else:
    lines = src.splitlines()
    # Find end of imports
    import_end = 0
    for i, line in enumerate(lines):
        if line.startswith("import ") or line.startswith("from "):
            import_end = i + 1
    inject = [
        "",
        "# Managed Agents commands extension",
        "import sys",
        "sys.path.insert(0, \"/home/ubuntu/agents-cc/shared\")",
        "try:",
        "    from ma_commands import dispatch as ma_dispatch",
        "except ImportError:",
        "    ma_dispatch = lambda *a, **kw: False",
        "",
    ]
    lines[import_end:import_end] = inject
    src = "\n".join(lines)
    # Insert dispatch hook into command handler
    m = re.search(r"def handle_command\([^)]*\):\s*\n", src)
    if m:
        inject_call = "    if ma_dispatch(cmd, parts[1:] if len(parts) > 1 else [], chat_id, send_message):\n        return\n"
        src = src[:m.end()] + inject_call + src[m.end():]
    p.write_text(src)
    print("[patched]", p)
PY

systemctl --user restart telegram-bot-v2
sleep 3
systemctl --user status telegram-bot-v2 --no-pager | head -5'

echo ""
echo "[done] Test in your Telegram chat:"
echo "  /agents   /cost   /killswitch   /killall   /ma <preset> <message>"
