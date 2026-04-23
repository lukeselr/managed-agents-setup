#!/usr/bin/env bash
# create-routine.sh — Create a Claude Code routine (cloud scheduled task).
# Requires: RemoteTrigger tool available OR interactive fallback via claude.ai/code/routines.
#
# Usage:
#   create-routine.sh --name NAME --cron "0 23 * * *" --prompt "PROMPT" --repo URL --env-id ENV
#
# Note: This script FORMATS the create body and prints it. RemoteTrigger API is
# not exposed via a public REST endpoint as of 2026-04-23 — the create call must
# be made from within a Claude Code session that has RemoteTrigger loaded, OR via
# the web UI at claude.ai/code/routines.
#
# When run, this script prints the JSON body you can paste into:
#   - A Claude Code prompt: "Create a routine with: <paste>"
#   - The RemoteTrigger tool call directly
set -euo pipefail

NAME=""
CRON=""
PROMPT=""
REPO=""
ENV_ID=""
RUN_ONCE_AT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --name) NAME="$2"; shift 2 ;;
    --cron) CRON="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --env-id) ENV_ID="$2"; shift 2 ;;
    --run-once-at) RUN_ONCE_AT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$NAME" ] || [ -z "$PROMPT" ] || [ -z "$REPO" ] || [ -z "$ENV_ID" ]; then
  echo "Usage: create-routine.sh --name N --cron CRON --prompt P --repo URL --env-id ENV [--run-once-at ISO]" >&2
  exit 2
fi
if [ -z "$CRON" ] && [ -z "$RUN_ONCE_AT" ]; then
  echo "[fatal] --cron or --run-once-at required" >&2
  exit 2
fi

# Generate UUIDv4 for event
UUID=$(python3 -c "import uuid; print(uuid.uuid4())")

# Build schedule portion
if [ -n "$RUN_ONCE_AT" ]; then
  SCHEDULE="\"run_once_at\": \"$RUN_ONCE_AT\""
else
  SCHEDULE="\"cron_expression\": \"$CRON\""
fi

# Escape prompt for JSON (basic — relies on prompt not containing raw newlines; multi-line prompts should use a file)
PROMPT_ESCAPED=$(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$PROMPT")

cat <<JSON
{
  "name": "$NAME",
  $SCHEDULE,
  "enabled": true,
  "job_config": {
    "ccr": {
      "environment_id": "$ENV_ID",
      "session_context": {
        "model": "claude-sonnet-4-6",
        "sources": [{"git_repository": {"url": "$REPO"}}],
        "allowed_tools": ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "Task"]
      },
      "events": [{
        "data": {
          "uuid": "$UUID",
          "session_id": "",
          "type": "user",
          "parent_tool_use_id": null,
          "message": {"content": $PROMPT_ESCAPED, "role": "user"}
        }
      }]
    }
  }
}
JSON

cat <<NEXT >&2

[next] To create this routine, either:
  A) Inside a Claude Code session with RemoteTrigger: call RemoteTrigger.create(body={...})
  B) Paste the JSON above into https://claude.ai/code/routines (New routine > Advanced)
  C) Ask Claude: "Create a routine with the following config: <paste JSON>"

After creation, save the trigger ID:
  echo "trig_..." > ~/.claude/managed-agents/routines/$NAME.trig

To fire it manually:
  bash ~/.claude/skills/managed-agents-setup/scripts/fire-routine.sh trig_...
NEXT
