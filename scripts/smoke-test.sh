#!/usr/bin/env bash
# smoke-test.sh — End-to-end verification of Managed Agents setup.
set -uo pipefail

STATE_DIR="$HOME/.claude/managed-agents"
PASS=0
FAIL=0

check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "[PASS] $label"
    PASS=$((PASS+1))
  else
    echo "[FAIL] $label"
    FAIL=$((FAIL+1))
  fi
}

echo "=== Managed Agents Smoke Test ==="
echo ""

check "ant CLI installed"  command -v ant
check "python3 installed"  command -v python3
check "anthropic SDK"      python3 -c "import anthropic"
check "jq installed"       command -v jq
check "API key in env"     test -n "${ANTHROPIC_API_KEY:-}"
check "API key in keychain" security find-generic-password -a "$USER" -s "anthropic-managed-agents" -w

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  check "API reachable (models endpoint)" bash -c "curl -sS -f 'https://api.anthropic.com/v1/models' -H 'x-api-key: $ANTHROPIC_API_KEY' -H 'anthropic-version: 2023-06-01' >/dev/null"
  check "Agents endpoint reachable" bash -c "curl -sS -f 'https://api.anthropic.com/v1/agents' -H 'x-api-key: $ANTHROPIC_API_KEY' -H 'anthropic-version: 2023-06-01' -H 'anthropic-beta: managed-agents-2026-04-01' >/dev/null"
fi

check "vault-id.txt exists"   test -f "$STATE_DIR/vault-id.txt"
check "env-id.txt exists"     test -f "$STATE_DIR/env-id.txt"
check "at least one agent id" bash -c "ls $STATE_DIR/agents/*.txt 2>/dev/null | head -1 | grep -q ."

echo ""
echo "=== Result: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
echo "Smoke test OK."
