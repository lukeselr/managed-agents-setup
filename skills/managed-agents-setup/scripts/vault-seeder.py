#!/usr/bin/env python3
"""
vault-seeder.py — Seed an Anthropic Vault from a secrets.env file.

Reads known env keys, maps them to MCP server URLs via mcp-servers-catalog.md,
creates a vault, and adds one credential per MCP server.

Usage:
  python3 vault-seeder.py --secrets-env PATH [--vault-name NAME] [--dry-run]

Env:
  ANTHROPIC_API_KEY — required.
"""
import argparse
import json
import os
import pathlib
import re
import sys
from typing import Dict, Optional
from urllib.parse import urlparse

try:
    import httpx
except ImportError:
    print("[fatal] httpx not installed. Run: pip3 install --user httpx", file=sys.stderr)
    sys.exit(1)

API = "https://api.anthropic.com/v1"
BETA = "managed-agents-2026-04-01"
STATE_DIR = pathlib.Path.home() / ".claude" / "managed-agents"
STATE_DIR.mkdir(parents=True, exist_ok=True)

# Map env var name -> (MCP server URL, auth type, credential display name)
# Multiple env vars can point to the same URL — vault-seeder dedupes by URL so
# whichever one is populated wins. This makes the seeder tolerant of varied naming
# conventions (Luke's server uses HIGHLEVEL_TOKEN; others use GHL_API_KEY).
MAPPINGS = {
    # GoHighLevel aliases
    "GHL_API_KEY":           ("https://services.leadconnectorhq.com/mcp/",            "static_bearer", "GoHighLevel"),
    "GHL_PIT_TOKEN":         ("https://services.leadconnectorhq.com/mcp/",            "static_bearer", "GoHighLevel PIT"),
    "HIGHLEVEL_TOKEN":       ("https://services.leadconnectorhq.com/mcp/",            "static_bearer", "HighLevel Token"),
    # Supabase
    "SUPABASE_SERVICE_KEY":  ("https://mcp.supabase.com",               "static_bearer", "Supabase Service"),
    "SUPABASE_ANON_KEY":     ("https://mcp.supabase.com",               "static_bearer", "Supabase Anon"),
    # Meta Ads aliases
    "META_ADS_TOKEN":        ("https://mcp.meta.com/ads",               "static_bearer", "Meta Ads"),
    "META_CAPI_TOKEN":       ("https://mcp.meta.com/ads",               "static_bearer", "Meta CAPI Token"),
    # ManyChat
    "MANYCHAT_API_KEY":      ("https://mcp.manychat.com",               "static_bearer", "ManyChat"),
    # Notion aliases
    "NOTION_TOKEN":          ("https://mcp.notion.com/mcp",             "static_bearer", "Notion"),
    "NOTION_API_KEY":        ("https://mcp.notion.com/mcp",             "static_bearer", "Notion API"),
    # OpenAI fallback
    "OPENAI_API_KEY":        ("https://mcp.openai.com",                 "static_bearer", "OpenAI (fallback)"),
    # Stripe aliases
    "STRIPE_API_KEY":        ("https://mcp.stripe.com",                 "static_bearer", "Stripe"),
    "STRIPE_SECRET_KEY":     ("https://mcp.stripe.com",                 "static_bearer", "Stripe Secret"),
    # Telegram
    "TELEGRAM_BOT_TOKEN":    ("https://mcp.telegram.org",               "static_bearer", "Telegram"),
    # Hubstaff / Xero / n8n
    "HUBSTAFF_API_TOKEN":    ("https://mcp.hubstaff.com",               "static_bearer", "Hubstaff"),
    "XERO_ACCESS_TOKEN":     ("https://mcp.xero.com",                   "static_bearer", "Xero"),
    "N8N_API_KEY":           ("https://selrai.app.n8n.cloud/mcp",       "static_bearer", "n8n"),
    # GitHub
    "GITHUB_TOKEN":          ("https://api.githubcopilot.com/mcp/",     "static_bearer", "GitHub"),
    # Rube / Composio — "one connection, 500+ services" meta-MCP.
    # Two paths:
    #   (a) RUBE_OAUTH_REFRESH  -> rube.app/mcp via mcp_oauth (preferred for workshop attendees)
    #   (b) COMPOSIO_API_KEY    -> backend.composio.dev via static_bearer (headless server path)
    "COMPOSIO_API_KEY":      ("https://backend.composio.dev/v3/mcp",    "static_bearer", "Rube/Composio (static)"),
}


def parse_env_file(path: pathlib.Path) -> Dict[str, str]:
    """Parse a shell-style secrets.env. Handles `export KEY=value` AND `KEY=value`."""
    out = {}
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        # Strip leading `export ` if present (common in shell-sourced secrets files)
        if line.startswith("export "):
            line = line[len("export "):]
        k, _, v = line.partition("=")
        v = v.strip().strip("'").strip('"')
        if k.strip() and v:
            out[k.strip()] = v
    return out


def ant_request(method: str, path: str, api_key: str, body: Optional[dict] = None) -> dict:
    headers = {
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
        "anthropic-beta": BETA,
        "content-type": "application/json",
    }
    r = httpx.request(method, f"{API}{path}", headers=headers, json=body, timeout=30)
    if r.status_code >= 400:
        raise RuntimeError(f"[{method} {path}] {r.status_code}: {r.text}")
    return r.json()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secrets-env", required=True, help="Path to secrets.env")
    ap.add_argument("--vault-name", default="primary")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("[fatal] ANTHROPIC_API_KEY not set", file=sys.stderr)
        sys.exit(2)

    secrets_path = pathlib.Path(args.secrets_env).expanduser()
    env = parse_env_file(secrets_path)
    if not env:
        print(f"[fatal] No usable env vars in {secrets_path}", file=sys.stderr)
        sys.exit(2)

    to_seed = []
    for key, (mcp_url, auth_type, display_name) in MAPPINGS.items():
        if key in env:
            to_seed.append({
                "env_key": key,
                "mcp_url": mcp_url,
                "auth_type": auth_type,
                "display_name": display_name,
                "token": env[key],
            })

    print(f"[seed] Detected {len(to_seed)} mappable secrets from {secrets_path.name}")
    for item in to_seed:
        print(f"  - {item['env_key']} -> {item['mcp_url']} ({item['display_name']})")

    if not to_seed:
        print("[seed] Nothing to seed. Exiting.")
        return

    if args.dry_run:
        print("[seed] Dry run; would create vault + credentials.")
        return

    print(f"[seed] Creating vault '{args.vault_name}'...")
    vault = ant_request("POST", "/vaults", api_key, {
        "display_name": args.vault_name,
        "metadata": {"created_by": "managed-agents-setup-skill"},
    })
    vault_id = vault["id"]
    (STATE_DIR / "vault-id.txt").write_text(vault_id)
    print(f"[seed] vault_id = {vault_id}")

    # Deduplicate by mcp_url — only one credential per URL per vault
    seen_urls = set()
    created = 0
    for item in to_seed:
        if item["mcp_url"] in seen_urls:
            print(f"[skip] {item['env_key']} — {item['mcp_url']} already covered in this vault")
            continue
        seen_urls.add(item["mcp_url"])

        try:
            cred = ant_request("POST", f"/vaults/{vault_id}/credentials", api_key, {
                "display_name": item["display_name"],
                "auth": {
                    "type": item["auth_type"],
                    "mcp_server_url": item["mcp_url"],
                    "token": item["token"],
                },
            })
            print(f"[ok]   {item['display_name']:20s} cred_id={cred['id']}")
            created += 1
        except RuntimeError as e:
            print(f"[fail] {item['display_name']}: {e}", file=sys.stderr)

    summary = {
        "vault_id": vault_id,
        "created": created,
        "skipped_duplicates": len(to_seed) - created,
        "secrets_env": str(secrets_path),
    }
    (STATE_DIR / "vault-summary.json").write_text(json.dumps(summary, indent=2))
    print(f"\n[done] {created} credentials created in vault {vault_id}")
    print(f"[done] Summary at {STATE_DIR / 'vault-summary.json'}")


if __name__ == "__main__":
    main()
