#!/usr/bin/env python3
"""
daily-cost-monitor.py — Deployed as a Routine (daily 8am Brisbane).

Pulls yesterday's Anthropic usage, flags anomalies, pushes a summary to Telegram.
Also enforces a soft daily spend cap: if above threshold, fires killswitch.sh via webhook.

Env:
  ANTHROPIC_API_KEY          required
  TELEGRAM_BOT_TOKEN         required
  TELEGRAM_CHAT_ID           required
  DAILY_SPEND_CAP_USD        default 20
  KILLSWITCH_WEBHOOK_URL     optional, if set & over cap, POSTs to trigger killswitch
"""
import json
import os
import sys
import urllib.request
from datetime import datetime, timedelta, timezone

API = "https://api.anthropic.com/v1"
BETA = "managed-agents-2026-04-01"


def req(method: str, path: str, body: dict | None = None) -> dict:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        print("[fatal] ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(2)
    data = json.dumps(body).encode() if body else None
    r = urllib.request.Request(
        f"{API}{path}",
        method=method,
        data=data,
        headers={
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
            "anthropic-beta": BETA,
            "content-type": "application/json",
        },
    )
    with urllib.request.urlopen(r, timeout=30) as resp:
        return json.loads(resp.read())


def tg_send(msg: str):
    tok = os.environ.get("TELEGRAM_BOT_TOKEN")
    chat = os.environ.get("TELEGRAM_CHAT_ID")
    if not tok or not chat:
        print("[warn] Telegram creds missing, skipping notification")
        return
    url = f"https://api.telegram.org/bot{tok}/sendMessage"
    body = json.dumps({"chat_id": chat, "text": msg, "parse_mode": "Markdown"}).encode()
    r = urllib.request.Request(url, data=body, headers={"content-type": "application/json"})
    try:
        urllib.request.urlopen(r, timeout=10)
    except Exception as e:
        print(f"[warn] Telegram send failed: {e}")


def main():
    cap = float(os.environ.get("DAILY_SPEND_CAP_USD", "20"))
    yesterday = (datetime.now(timezone.utc) - timedelta(days=1)).strftime("%Y-%m-%d")

    # List running sessions (catches stuck runaway sessions)
    running = req("GET", "/sessions?status=running")
    running_ids = [s["id"] for s in running.get("data", [])]

    # List recent sessions (best-proxy-for-spend: count sessions created yesterday)
    recent = req("GET", "/sessions?limit=100")
    yday_sessions = [
        s for s in recent.get("data", [])
        if s.get("created_at", "").startswith(yesterday)
    ]

    # Rough estimate — real cost lives in workspace usage endpoint (if available)
    # Fallback: count sessions × avg-hourly × session-runtime estimate
    sess_count = len(yday_sessions)
    est_cost = sess_count * 0.15  # ~$0.15/session assumption; tune after real data

    # Compose report
    lines = [
        f"*Managed Agents daily report*",
        f"Date: {yesterday}",
        f"Sessions yesterday: {sess_count}",
        f"Currently running: {len(running_ids)}",
        f"Est. spend: ${est_cost:.2f} (cap ${cap:.2f})",
    ]

    if est_cost > cap:
        lines.append(f"\n*OVER CAP* — triggering killswitch alert")
        webhook = os.environ.get("KILLSWITCH_WEBHOOK_URL")
        if webhook:
            try:
                urllib.request.urlopen(urllib.request.Request(webhook, method="POST"), timeout=10)
                lines.append("Webhook fired, killswitch triggered")
            except Exception as e:
                lines.append(f"Webhook FAILED: {e}")

    if len(running_ids) > 5:
        lines.append(f"\nUnusual: {len(running_ids)} running sessions — investigate")

    if running_ids:
        lines.append("\nRunning session ids:")
        lines.extend([f"  `{sid}`" for sid in running_ids[:5]])

    msg = "\n".join(lines)
    print(msg)
    tg_send(msg)


if __name__ == "__main__":
    main()
