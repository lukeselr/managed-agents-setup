#!/usr/bin/env bash
# rotate.sh — Credential rotation helper for Anthropic Vaults.
# Use when a GHL PIT expires, a Meta token rotates, or any service key needs refresh.
#
# Usage:
#   rotate.sh <service-name> [new-token-value]
#   rotate.sh --list                 # list all credentials in the vault
#   rotate.sh --interactive          # pick service from menu
#   rotate.sh --help                 # show help
#
# Services: ghl supabase meta manychat stripe telegram hubstaff xero notion composio openai n8n
set -o pipefail

KNOWN_SERVICES="ghl supabase meta manychat stripe telegram hubstaff xero notion composio openai n8n"

# Service → MCP URL (via case to avoid bash 3.2 assoc array requirement)
mcp_url_for() {
  case "$1" in
    ghl)      echo "https://mcp.gohighlevel.com" ;;
    supabase) echo "https://mcp.supabase.com" ;;
    meta)     echo "https://mcp.meta.com/ads" ;;
    manychat) echo "https://mcp.manychat.com" ;;
    stripe)   echo "https://mcp.stripe.com" ;;
    telegram) echo "https://mcp.telegram.org" ;;
    hubstaff) echo "https://mcp.hubstaff.com" ;;
    xero)     echo "https://mcp.xero.com" ;;
    notion)   echo "https://mcp.notion.com/mcp" ;;
    composio) echo "https://backend.composio.dev/v3/mcp" ;;
    openai)   echo "https://mcp.openai.com" ;;
    n8n)      echo "https://<your-n8n-domain>/mcp" ;;
    *)        echo "" ;;
  esac
}

rotation_url() {
  case "$1" in
    ghl)      echo "https://app.gohighlevel.com/settings/private_integrations" ;;
    supabase) echo "https://supabase.com/dashboard/project/_/settings/api" ;;
    meta)     echo "https://developers.facebook.com/tools/debug/accesstoken/" ;;
    manychat) echo "https://app.manychat.com/settings/api" ;;
    stripe)   echo "https://dashboard.stripe.com/apikeys" ;;
    telegram) echo "https://t.me/BotFather" ;;
    xero)     echo "https://developer.xero.com/myapps" ;;
    notion)   echo "https://www.notion.so/my-integrations" ;;
    composio) echo "https://app.composio.dev/api-keys" ;;
    *)        echo "" ;;
  esac
}

# --help works with zero env vars
case "${1:-}" in
  --help|-h)
    echo "Usage: rotate.sh <service>              # prompts for new token + opens rotation page"
    echo "       rotate.sh <service> <token>      # non-interactive"
    echo "       rotate.sh --list                 # show all vault credentials"
    echo "       rotate.sh --interactive          # menu-driven"
    echo ""
    echo "Services: $KNOWN_SERVICES"
    exit 0
    ;;
  "")
    echo "Usage: rotate.sh <service>. Try --help."
    exit 1
    ;;
esac

# Everything below requires Anthropic API key + vault
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set}"
VAULT_ID="${VAULT_ID:-$(cat "$HOME/.claude/managed-agents/vault-id.txt" 2>/dev/null || true)}"
: "${VAULT_ID:?Vault ID not found. Run vault-seeder.py first.}"

BETA="anthropic-beta: managed-agents-2026-04-01"
VER="anthropic-version: 2023-06-01"
KEY="x-api-key: $ANTHROPIC_API_KEY"

list_credentials() {
  echo "[list] Credentials in vault $VAULT_ID:"
  curl -sS "https://api.anthropic.com/v1/vaults/$VAULT_ID/credentials" \
    -H "$KEY" -H "$VER" -H "$BETA" \
    | jq -r '.data[]? | "  \(.display_name // "?")  [\(.id)]  -> \(.auth.mcp_server_url // "?")"'
}

rotate_one() {
  local service="$1"
  local new_token="${2:-}"
  local url
  url=$(mcp_url_for "$service")
  if [ -z "$url" ]; then
    echo "[fail] Unknown service: $service" >&2
    echo "Known: $KNOWN_SERVICES" >&2
    exit 2
  fi

  local cred_id
  cred_id=$(curl -sS "https://api.anthropic.com/v1/vaults/$VAULT_ID/credentials" \
    -H "$KEY" -H "$VER" -H "$BETA" \
    | jq -r --arg u "$url" '.data[] | select(.auth.mcp_server_url==$u) | .id' | head -1)

  if [ -z "$cred_id" ]; then
    echo "[warn] No existing credential for $url. Creating new."
  else
    echo "[info] Found existing credential $cred_id for $url"
  fi

  if [ -z "$new_token" ]; then
    local rot_url
    rot_url=$(rotation_url "$service")
    if [ -n "$rot_url" ]; then
      echo "[open] Opening rotation page: $rot_url"
      open "$rot_url" 2>/dev/null || echo "  (open manually: $rot_url)"
    fi
    echo ""
    read -rsp "  Paste new token: " new_token
    echo ""
  fi
  [ -z "$new_token" ] && { echo "[abort] No token provided"; exit 1; }

  if [ -n "$cred_id" ]; then
    echo "[rotate] Updating credential $cred_id..."
    curl -sS -X POST "https://api.anthropic.com/v1/vaults/$VAULT_ID/credentials/$cred_id" \
      -H "$KEY" -H "$VER" -H "$BETA" -H "content-type: application/json" \
      -d "{\"auth\":{\"type\":\"static_bearer\",\"mcp_server_url\":\"$url\",\"token\":\"$new_token\"}}" \
      | jq -r '.id // .error // "?"'
  else
    echo "[create] Creating credential..."
    curl -sS -X POST "https://api.anthropic.com/v1/vaults/$VAULT_ID/credentials" \
      -H "$KEY" -H "$VER" -H "$BETA" -H "content-type: application/json" \
      -d "{\"display_name\":\"$service\",\"auth\":{\"type\":\"static_bearer\",\"mcp_server_url\":\"$url\",\"token\":\"$new_token\"}}" \
      | jq -r '.id // .error // "?"'
  fi

  echo "[ok] Rotated $service. Sessions pick up new value on next tool call."
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"service\":\"$service\",\"vault\":\"$VAULT_ID\"}" \
    >> "$HOME/.claude/managed-agents/rotate.log"
}

interactive() {
  echo "Services: $KNOWN_SERVICES"
  read -rp "Pick service: " svc
  rotate_one "$svc"
}

case "$1" in
  --list|-l) list_credentials ;;
  --interactive|-i) interactive ;;
  *) rotate_one "$1" "${2:-}" ;;
esac
