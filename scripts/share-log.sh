#!/usr/bin/env bash
# share-log.sh — Redact + upload install.log to a private gist, return a short ID.
# Use when: install fails and user wants a maintainer to look at it.
#
# Output: short ID (e.g. "abc123") that maps to a private gist URL.
# Support: the maintainer pastes the ID into `get-support-log.sh abc123` which resolves to the gist.
set -euo pipefail

LOG_FILE="${INSTALL_LOG_FILE:-$HOME/.claude/managed-agents/install.log}"

if [ ! -f "$LOG_FILE" ]; then
  echo "[share] No install log found at $LOG_FILE" >&2
  exit 1
fi

# Redact secrets before upload
REDACTED=$(python3 <<PY
import json, re, sys
with open("$LOG_FILE") as f:
    lines = f.readlines()

redacted = []
for line in lines:
    # Strip anything that looks like a token
    line = re.sub(r'(sk-ant-[a-zA-Z0-9\-_]{30,})', '[REDACTED-ANTHROPIC-KEY]', line)
    line = re.sub(r'(Bearer\s+)[a-zA-Z0-9\-_.]{20,}', r'\1[REDACTED]', line)
    line = re.sub(r'"token":\s*"[^"]+"', '"token":"[REDACTED]"', line)
    line = re.sub(r'(eyJ[a-zA-Z0-9\-_.]{30,})', '[REDACTED-JWT]', line)
    line = re.sub(r'ghp_[a-zA-Z0-9]{30,}', '[REDACTED-GITHUB]', line)
    line = re.sub(r'pat-[a-zA-Z0-9\-]{20,}', '[REDACTED-PAT]', line)
    redacted.append(line)

print(''.join(redacted))
PY
)

# Need gh CLI for gist upload
if ! command -v gh >/dev/null 2>&1; then
  echo "[share] gh CLI required. Install: brew install gh" >&2
  exit 2
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "[share] Not logged into gh. Run: gh auth login" >&2
  exit 2
fi

# Create a gist
TMP=$(mktemp)
printf '%s\n' "$REDACTED" > "$TMP"
GIST_URL=$(gh gist create --desc "managed-agents-setup install log" "$TMP" 2>&1 | tail -1)
rm -f "$TMP"

# Short ID is just the last 8 chars of the gist URL
SHORT_ID=$(echo "$GIST_URL" | awk -F/ '{print $NF}' | cut -c1-8)

cat <<EOF

[share] Log uploaded.
[share] Short ID: $SHORT_ID
[share] Full URL: $GIST_URL

Send the short ID to the maintainer to get support.
EOF

# Persist the ID locally
echo "{\"short_id\":\"$SHORT_ID\",\"gist_url\":\"$GIST_URL\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
  > "$HOME/.claude/managed-agents/last-share.json"
