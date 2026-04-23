#!/usr/bin/env python3
"""
run-session.py — Create a Managed Agents session, send a message, stream responses.

Uses raw HTTPX (Python SDK 0.84 doesn't have .beta.sessions typed methods yet).
Beta endpoint: POST /v1/sessions, POST /v1/sessions/{id}/events, GET /v1/sessions/{id}/stream

Usage:
  python3 run-session.py --agent-id AGENT --env-id ENV [--vault-id VAULT] --message "MSG"
  python3 run-session.py --session-id SES --message "MSG"  # resume existing session
"""
import argparse
import json
import os
import pathlib
import sys

try:
    import httpx
except ImportError:
    print("[fatal] httpx not installed. Run: pip3 install --user httpx", file=sys.stderr)
    sys.exit(1)

API = "https://api.anthropic.com/v1"
# Managed Agents beta. Note: /sessions/{id}/stream uses a DIFFERENT beta
# (agent-api-2026-03-01) that is incompatible with managed-agents-*.
# This script polls the events list endpoint instead — equivalent UX, works today.
BETA = "managed-agents-2026-04-01"
STATE_DIR = pathlib.Path.home() / ".claude" / "managed-agents"
STATE_DIR.mkdir(parents=True, exist_ok=True)


def headers(key: str) -> dict:
    return {
        "x-api-key": key,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": BETA,
        "content-type": "application/json",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent-id")
    ap.add_argument("--env-id")
    ap.add_argument("--vault-id")
    ap.add_argument("--session-id", help="Resume existing session")
    ap.add_argument("--message", required=True)
    ap.add_argument("--title", default="Skill smoke test")
    ap.add_argument("--timeout", type=int, default=120, help="Max wall-clock seconds to stream")
    args = ap.parse_args()

    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        print("[fatal] ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(2)
    h = headers(key)

    # Create or resume session
    if args.session_id:
        session_id = args.session_id
        print(f"[session] Resuming {session_id}")
    else:
        if not args.agent_id or not args.env_id:
            print("[fatal] --agent-id and --env-id required", file=sys.stderr)
            sys.exit(2)
        body = {"agent": args.agent_id, "environment_id": args.env_id, "title": args.title}
        if args.vault_id:
            body["vault_ids"] = [args.vault_id]
        r = httpx.post(f"{API}/sessions", headers=h, json=body, timeout=30)
        if r.status_code >= 400:
            print(f"[fatal] session create {r.status_code}: {r.text}", file=sys.stderr)
            sys.exit(3)
        session = r.json()
        session_id = session["id"]
        print(f"[session] Created {session_id}")
        (STATE_DIR / "last-session-id.txt").write_text(session_id)

    # Send the user message (events endpoint)
    msg_body = {
        "events": [
            {"type": "user.message", "content": [{"type": "text", "text": args.message}]}
        ]
    }
    r2 = httpx.post(f"{API}/sessions/{session_id}/events", headers=h, json=msg_body, timeout=30)
    if r2.status_code >= 400:
        print(f"[fatal] send event {r2.status_code}: {r2.text}", file=sys.stderr)
        sys.exit(4)
    print(f"[session] Message sent. Polling for response...")

    import time
    start = time.time()
    seen = set()
    printed_any = False
    while time.time() - start < args.timeout:
        # List events
        r3 = httpx.get(f"{API}/sessions/{session_id}/events", headers=h, timeout=30)
        if r3.status_code >= 400:
            print(f"[fatal] list events {r3.status_code}: {r3.text}", file=sys.stderr)
            sys.exit(5)

        events = r3.json().get("data", [])
        # Print any new agent.message events
        for i, ev in enumerate(events):
            if i in seen:
                continue
            seen.add(i)
            etype = ev.get("type", "")
            if etype == "agent.message":
                for block in ev.get("content", []):
                    text = block.get("text")
                    if text:
                        if printed_any:
                            print()
                        print(text, end="", flush=True)
                        printed_any = True
            elif etype == "agent.tool_use":
                name = ev.get("name", "?")
                print(f"\n[tool:{name}]", end="", flush=True)
            elif etype == "session.error":
                err = ev.get("error") or ev
                print(f"\n[session] ERROR: {json.dumps(err)[:500]}", file=sys.stderr)
                sys.exit(6)

        # Check session status for idle completion
        s_resp = httpx.get(f"{API}/sessions/{session_id}", headers=h, timeout=30)
        status = s_resp.json().get("status", "?")
        if status == "idle" and any(ev.get("type") == "agent.message" for ev in events):
            print("\n[session] idle — done.")
            break
        if status == "terminated":
            print("\n[session] terminated.")
            break

        time.sleep(1.5)
    else:
        print(f"\n[warn] timeout after {args.timeout}s")

    print(f"[done] session_id = {session_id}")
    if not printed_any:
        print("[warn] no agent message content found")


if __name__ == "__main__":
    main()
