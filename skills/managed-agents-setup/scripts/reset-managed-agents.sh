#!/usr/bin/env bash
# reset-managed-agents.sh — Rollback script. Archives every resource this skill created.
# Idempotent, logged, safe to run twice. Use after a failed install or to start clean.
#
# What gets archived:
#  - Every session_id in ~/.claude/managed-agents/last-session-id.txt (and any in state)
#  - Every agent_id in ~/.claude/managed-agents/agents/*.txt
#  - env_id in ~/.claude/managed-agents/env-id.txt
#  - vault_id in ~/.claude/managed-agents/vault-id.txt
#  - Every routine trig_id in ~/.claude/managed-agents/routines/*.trig (if using routines)
#
# Does NOT touch:
#  - The API key (keychain stays)
#  - The workspace (manual on Anthropic console)
#  - The server (run separately: ssh + remove ~/agents-cc/shared/managed-agents/)
set -uo pipefail

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY not set}"

STATE_DIR="$HOME/.claude/managed-agents"
LOG="$STATE_DIR/reset.log"
BETA="anthropic-beta: managed-agents-2026-04-01"
VERSION="anthropic-version: 2023-06-01"
KEY="x-api-key: $ANTHROPIC_API_KEY"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ ! -d "$STATE_DIR" ]; then
  echo "[reset] No $STATE_DIR — nothing to roll back"
  exit 0
fi

echo "[reset] $TS starting rollback"
echo "[reset] $TS starting rollback" >> "$LOG"

archive() {
  local kind="$1"  # agents | environments | vaults | sessions
  local id="$2"
  [ -z "$id" ] && return 0
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "https://api.anthropic.com/v1/$kind/$id/archive" \
    -H "$KEY" -H "$VERSION" -H "$BETA")
  if [ "$code" = "200" ] || [ "$code" = "204" ]; then
    echo "  [ok]   $kind/$id" | tee -a "$LOG"
  elif [ "$code" = "404" ]; then
    echo "  [gone] $kind/$id (already archived/deleted)" | tee -a "$LOG"
  else
    echo "  [fail] $kind/$id (http=$code)" | tee -a "$LOG"
  fi
}

# Sessions first (must interrupt before archive if still running)
echo "[reset] Sessions..."
# Collect from multiple possible sources
SESSIONS=""
[ -f "$STATE_DIR/last-session-id.txt" ] && SESSIONS="$(cat $STATE_DIR/last-session-id.txt)"
if [ -d "$STATE_DIR/sessions" ]; then
  for f in "$STATE_DIR"/sessions/*.txt; do
    [ -f "$f" ] && SESSIONS="$SESSIONS $(cat $f)"
  done
fi
# Also query the API for any "primary" vault'd session still running
LIVE=$(curl -sS "https://api.anthropic.com/v1/sessions?status=running" \
  -H "$KEY" -H "$VERSION" -H "$BETA" | jq -r '.data[]?.id // empty')
SESSIONS="$SESSIONS $LIVE"
for SID in $SESSIONS; do
  [ -z "$SID" ] && continue
  # Interrupt first
  curl -sS -X POST "https://api.anthropic.com/v1/sessions/$SID/events" \
    -H "$KEY" -H "$VERSION" -H "$BETA" -H "content-type: application/json" \
    -d '{"events":[{"type":"user.interrupt"}]}' >/dev/null 2>&1 || true
  sleep 1
  archive "sessions" "$SID"
done

# Agents
echo "[reset] Agents..."
if [ -d "$STATE_DIR/agents" ]; then
  for f in "$STATE_DIR"/agents/*.txt; do
    [ -f "$f" ] || continue
    archive "agents" "$(cat "$f")"
  done
fi

# Environment
echo "[reset] Environment..."
if [ -f "$STATE_DIR/env-id.txt" ]; then
  archive "environments" "$(cat "$STATE_DIR/env-id.txt")"
fi

# Vault
echo "[reset] Vault..."
if [ -f "$STATE_DIR/vault-id.txt" ]; then
  archive "vaults" "$(cat "$STATE_DIR/vault-id.txt")"
fi

# Routines (note: RemoteTrigger has no DELETE; can only disable)
echo "[reset] Routines (disable only — Anthropic has no delete API)..."
if [ -d "$STATE_DIR/routines" ]; then
  for f in "$STATE_DIR"/routines/*.trig; do
    [ -f "$f" ] || continue
    TRIG=$(cat "$f")
    echo "  [manual] routines/$TRIG — delete via https://claude.ai/code/routines UI" | tee -a "$LOG"
  done
fi

# Preserve the log, but archive the state dir
echo "[reset] Archiving $STATE_DIR..."
BACKUP="$STATE_DIR.rolled-back.$(date +%s)"
cp -R "$STATE_DIR" "$BACKUP"
# Clear state but keep the log
find "$STATE_DIR" -type f ! -name 'reset.log' ! -name 'rotate.log' -delete 2>/dev/null
find "$STATE_DIR" -type d -empty -delete 2>/dev/null
mkdir -p "$STATE_DIR"

echo ""
echo "[reset] $(date -u +%Y-%m-%dT%H:%M:%SZ) complete."
echo "[reset] Backup saved at $BACKUP"
echo "[reset] Log at $LOG"
echo ""
echo "To re-run the install: Agent({ subagent_type: 'managed-agents-setup', ... })"
