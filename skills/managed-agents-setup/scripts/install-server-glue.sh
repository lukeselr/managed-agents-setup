#!/usr/bin/env bash
# install-server-glue.sh — Install FastAPI webhook + cron + Telegram glue on the
# existing server-setup EC2 box. Replaces what a platform like n8n would do.
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/clawd-key.pem}"
SSH_HOST="${SSH_HOST:-ubuntu@100.119.119.120}"
WEBHOOK_PORT="${WEBHOOK_PORT:-8080}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:-$(python3 -c 'import secrets; print(secrets.token_hex(16))')}"

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set}"

SSH_CMD="ssh -i $SSH_KEY -o ConnectTimeout=5 $SSH_HOST"

echo "[glue] Checking server..."
if ! $SSH_CMD 'test -d ~/agents-cc' 2>/dev/null; then
  echo "[fatal] ~/agents-cc not found on server. Run server-setup first." >&2
  exit 3
fi

echo "[glue] Installing FastAPI + uvicorn..."
$SSH_CMD 'python3 -m pip install --user fastapi uvicorn httpx >/dev/null'

echo "[glue] Creating webhook-server directory..."
$SSH_CMD 'mkdir -p ~/agents-cc/webhook-server'

echo "[glue] Writing webhook app..."
$SSH_CMD 'cat > ~/agents-cc/webhook-server/app.py << '\''PY'\''
"""
FastAPI webhook receiver — inbound HTTP → Managed Agent session.
Routes:
  POST /hook/<name>    — fires a Managed Agent session with request body as message
  POST /fire/<trig_id> — fires a Claude Code routine (pass-through to /fire API)
  GET  /healthz        — liveness check

Each /hook/<name> is configured via ~/agents-cc/webhook-server/hooks.json
  {
    "inbound-lead": {"agent_id": "agent_...", "env_id": "env_...", "vault_id": "vlt_..."},
    ...
  }
"""
import json
import os
import pathlib
import httpx
from fastapi import FastAPI, Header, HTTPException, Request

API = "https://api.anthropic.com/v1"
BETA = "managed-agents-2026-04-01"
ROUTINE_BETA = "experimental-cc-routine-2026-04-01"
SECRET = os.environ.get("WEBHOOK_SECRET", "")
API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
ROUTINE_OAT = os.environ.get("ROUTINE_OAT_TOKEN", "")
HOOKS_FILE = pathlib.Path.home() / "agents-cc/webhook-server/hooks.json"

app = FastAPI(title="Agent Glue")


def load_hooks():
    if HOOKS_FILE.exists():
        return json.loads(HOOKS_FILE.read_text())
    return {}


@app.get("/healthz")
def healthz():
    return {"ok": True, "hooks": list(load_hooks().keys())}


@app.post("/hook/{name}")
async def fire_hook(name: str, request: Request, x_webhook_secret: str = Header(default="")):
    if SECRET and x_webhook_secret != SECRET:
        raise HTTPException(401, "bad secret")
    hooks = load_hooks()
    if name not in hooks:
        raise HTTPException(404, f"hook {name} not configured")

    cfg = hooks[name]
    agent_id = cfg["agent_id"]
    env_id = cfg["env_id"]
    vault_id = cfg.get("vault_id")

    body = await request.body()
    payload = body.decode("utf-8", errors="replace") or "{}"

    session_body = {
        "agent": agent_id,
        "environment_id": env_id,
        "title": f"glue-{name}",
    }
    if vault_id:
        session_body["vault_ids"] = [vault_id]

    headers = {
        "x-api-key": API_KEY,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": BETA,
        "content-type": "application/json",
    }
    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.post(f"{API}/sessions", headers=headers, json=session_body)
        r.raise_for_status()
        session = r.json()
        sid = session["id"]

        msg = {"events": [{"type": "user.message", "content": [{"type": "text", "text": payload}]}]}
        r2 = await c.post(f"{API}/sessions/{sid}/events", headers=headers, json=msg)
        r2.raise_for_status()

    return {"session_id": sid, "url": f"https://platform.claude.com/sessions/{sid}"}


@app.post("/fire/{trig_id}")
async def fire_routine(trig_id: str, request: Request, x_webhook_secret: str = Header(default="")):
    if SECRET and x_webhook_secret != SECRET:
        raise HTTPException(401, "bad secret")
    if not ROUTINE_OAT:
        raise HTTPException(500, "ROUTINE_OAT_TOKEN not set")
    body = await request.body()
    text = body.decode("utf-8", errors="replace") or "glue triggered"

    headers = {
        "Authorization": f"Bearer {ROUTINE_OAT}",
        "anthropic-version": "2023-06-01",
        "anthropic-beta": ROUTINE_BETA,
        "content-type": "application/json",
    }
    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.post(f"{API}/claude_code/routines/{trig_id}/fire", headers=headers, json={"text": text})
        return {"status": r.status_code, "body": r.text}
PY'

echo "[glue] Seeding hooks.json (empty)..."
$SSH_CMD 'test -f ~/agents-cc/webhook-server/hooks.json || echo "{}" > ~/agents-cc/webhook-server/hooks.json'

echo "[glue] Injecting secret + API key into secrets.env..."
$SSH_CMD "sed -i '/^# --- Glue ---/,/^# --- End Glue ---/d' ~/agents-cc/shared/secrets.env 2>/dev/null || true"
$SSH_CMD "cat >> ~/agents-cc/shared/secrets.env <<ENV

# --- Glue ---
export ANTHROPIC_API_KEY=\"$ANTHROPIC_API_KEY\"
export WEBHOOK_SECRET=\"$WEBHOOK_SECRET\"
# --- End Glue ---
ENV"

echo "[glue] Installing systemd user service..."
$SSH_CMD 'mkdir -p ~/.config/systemd/user && cat > ~/.config/systemd/user/webhook-server.service << '\''UNIT'\''
[Unit]
Description=Agent Glue Webhook Server
After=network.target

[Service]
Type=simple
EnvironmentFile=%h/agents-cc/shared/secrets.env
WorkingDirectory=%h/agents-cc/webhook-server
ExecStart=/home/ubuntu/.local/bin/uvicorn app:app --host 0.0.0.0 --port '"$WEBHOOK_PORT"'
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT'

$SSH_CMD 'loginctl enable-linger ubuntu 2>/dev/null || true'
$SSH_CMD 'systemctl --user daemon-reload && systemctl --user enable webhook-server && systemctl --user restart webhook-server'

echo "[glue] Waiting for service..."
sleep 3
if $SSH_CMD "curl -sS -f http://localhost:$WEBHOOK_PORT/healthz" >/dev/null; then
  echo "[ok] Webhook server live on port $WEBHOOK_PORT"
else
  echo "[warn] Webhook server not responding — check: ssh $SSH_HOST 'journalctl --user -u webhook-server -n 50'"
fi

echo ""
echo "[ok] Server glue installed."
echo "    Webhook secret (save this): $WEBHOOK_SECRET"
echo "    Configure hooks: ssh $SSH_HOST 'vim ~/agents-cc/webhook-server/hooks.json'"
echo "    Fire a hook: curl -X POST http://<SERVER>:$WEBHOOK_PORT/hook/<name> -H 'X-Webhook-Secret: $WEBHOOK_SECRET' -d 'payload'"
echo ""
echo "[next] See references/server-glue-patterns.md for cron + Telegram patterns."
