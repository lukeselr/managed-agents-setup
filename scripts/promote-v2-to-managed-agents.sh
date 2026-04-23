#!/usr/bin/env bash
# promote-v2-to-managed-agents.sh — Reads server v2 CLAUDE.md files and creates
# corresponding Managed Agent definitions for each. v2 local ghost is archived.
#
# Pattern B from server audit: v2 agent files become Managed Agent system prompts,
# v1 agents on cron delegate heavy work to v2 (now hosted).
#
# Usage:
#   bash promote-v2-to-managed-agents.sh [--dry-run]
set -uo pipefail

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set}"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

SSH_KEY="${SSH_KEY:-$HOME/.ssh/clawd-key.pem}"
SSH_HOST="${SSH_HOST:-<YOUR_SERVER_USER>@<YOUR_SERVER_IP>}"
SSH_CMD="ssh -o BatchMode=yes -i $SSH_KEY $SSH_HOST"

STATE_DIR="$HOME/.claude/managed-agents"
mkdir -p "$STATE_DIR/agents" "$STATE_DIR/v2-prompts"

# Pull each v2 CLAUDE.md locally so we can read them
echo "[promote] Pulling v2 CLAUDE.mds from server..."
$SSH_CMD 'ls -d ~/agents-v2/agents/*/ 2>/dev/null | xargs -I{} basename {}' > /tmp/v2_agents.txt
V2_AGENTS=$(cat /tmp/v2_agents.txt)

if [ -z "$V2_AGENTS" ]; then
  echo "[info] No v2 agents found on server. Nothing to promote."
  exit 0
fi

echo "[promote] Found v2 agents:"
for a in $V2_AGENTS; do echo "  - $a"; done

: "${ENV_ID:=$(cat $STATE_DIR/env-id.txt 2>/dev/null)}"
: "${VAULT_ID:=$(cat $STATE_DIR/vault-id.txt 2>/dev/null)}"

if [ -z "$ENV_ID" ]; then
  echo "[fatal] No env_id found. Run create-environment.sh first."
  exit 2
fi

# Model mapping — different v2 agents justify different tiers
pick_model() {
  case "$1" in
    brain|dealmaker|research*) echo "claude-opus-4-7" ;;
    ops|finance|events)        echo "claude-haiku-4-5" ;;
    *)                         echo "claude-sonnet-4-6" ;;
  esac
}

BETA="managed-agents-2026-04-01"

for AGENT in $V2_AGENTS; do
  echo ""
  echo "══ Promoting: $AGENT ══"

  # Fetch CLAUDE.md content
  PROMPT=$($SSH_CMD "cat ~/agents-v2/agents/$AGENT/CLAUDE.md 2>/dev/null" || echo "")
  if [ -z "$PROMPT" ]; then
    echo "  [skip] No CLAUDE.md for $AGENT"
    continue
  fi

  cp /dev/stdin "$STATE_DIR/v2-prompts/$AGENT.md" <<< "$PROMPT"
  MODEL=$(pick_model "$AGENT")

  # Truncate long prompts (Managed Agents has a prompt size cap — be safe)
  PROMPT_SHORT=$(echo "$PROMPT" | head -c 10000)

  BODY=$(python3 <<PY
import json, sys
body = {
    "name": f"v2-$AGENT".replace("_", "-"),
    "model": "$MODEL",
    "system": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$PROMPT_SHORT"),
    "tools": [{"type": "agent_toolset_20260401"}]
}
if "$VAULT_ID":
    # Add Rube by default for universal tool access
    body["mcp_servers"] = [{"type": "url", "name": "rube", "url": "https://rube.app/mcp"}]
    body["tools"].append({"type": "mcp_toolset", "mcp_server_name": "rube"})
print(json.dumps(body))
PY
)

  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry-run] Would create agent v2-$AGENT with model $MODEL"
    continue
  fi

  RESP=$(curl -sS -X POST "https://api.anthropic.com/v1/agents" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: $BETA" \
    -H "content-type: application/json" \
    -d "$BODY")

  AGENT_ID=$(echo "$RESP" | jq -r '.id // empty')
  if [ -n "$AGENT_ID" ]; then
    echo "$AGENT_ID" > "$STATE_DIR/agents/v2-$AGENT.txt"
    echo "  [ok] v2-$AGENT → $AGENT_ID (model $MODEL)"
  else
    echo "  [fail] $AGENT — $(echo "$RESP" | jq -c .)"
  fi
done

echo ""
echo "[promote] Done. Agent IDs saved to $STATE_DIR/agents/v2-*.txt"

# Archive the local v2 ghost (it's empty anyway, just marker)
if [ -d "$HOME/agents-v2" ]; then
  ARCHIVE="$HOME/archive/agents-v2-pre-managed-$(date +%Y%m%d)"
  mkdir -p "$HOME/archive"
  mv "$HOME/agents-v2" "$ARCHIVE" 2>/dev/null || true
  echo "[archive] Local ~/agents-v2 moved to $ARCHIVE"
fi
