#!/usr/bin/env python3
"""
run-session.py — Create a Managed Agents session, send a message, stream responses.

Usage:
  python3 run-session.py --agent-id AGENT --env-id ENV [--vault-id VAULT] --message "MSG"
  python3 run-session.py --session-id SES --message "MSG"  # resume existing session

Env:
  ANTHROPIC_API_KEY — required.
"""
import argparse
import json
import os
import sys
import pathlib

try:
    from anthropic import Anthropic
except ImportError:
    print("[fatal] anthropic not installed. Run: pip3 install --user anthropic", file=sys.stderr)
    sys.exit(1)


STATE_DIR = pathlib.Path.home() / ".claude" / "managed-agents"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--agent-id")
    ap.add_argument("--env-id")
    ap.add_argument("--vault-id")
    ap.add_argument("--session-id", help="Resume existing session instead of creating new")
    ap.add_argument("--message", required=True)
    ap.add_argument("--title", default="Skill smoke test")
    args = ap.parse_args()

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("[fatal] ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(2)

    client = Anthropic(default_headers={"anthropic-beta": "managed-agents-2026-04-01"})

    # Create or resume session
    if args.session_id:
        session_id = args.session_id
        print(f"[session] Resuming {session_id}")
    else:
        if not args.agent_id or not args.env_id:
            print("[fatal] --agent-id and --env-id required when creating a new session", file=sys.stderr)
            sys.exit(2)
        body = {"agent": args.agent_id, "environment_id": args.env_id, "title": args.title}
        if args.vault_id:
            body["vault_ids"] = [args.vault_id]
        # Use the beta API through the SDK — method names subject to SDK version
        session = client.beta.sessions.create(**body)
        session_id = session.id
        print(f"[session] Created {session_id}")
        (STATE_DIR / "last-session-id.txt").write_text(session_id)

    # Open stream THEN send message (per docs — opening after sending batches events)
    print(f"[session] Opening stream + sending message...")
    with client.beta.sessions.events.stream(session_id) as stream:
        client.beta.sessions.events.send(
            session_id,
            events=[{
                "type": "user.message",
                "content": [{"type": "text", "text": args.message}],
            }],
        )

        print(f"[session] --- agent response ---")
        for event in stream:
            etype = getattr(event, "type", None)
            if etype == "agent.message":
                for block in getattr(event, "content", []):
                    text = getattr(block, "text", None)
                    if text:
                        print(text, end="", flush=True)
            elif etype == "agent.tool_use":
                name = getattr(event, "name", "?")
                print(f"\n[tool:{name}]", end="", flush=True)
            elif etype in ("session.status_idle", "session.idle"):
                print("\n[session] idle — done.")
                break
            elif etype == "session.error":
                err = getattr(event, "error", event)
                print(f"\n[session] ERROR: {err}", file=sys.stderr)
                sys.exit(4)

    print(f"\n[done] session_id = {session_id}")


if __name__ == "__main__":
    main()
