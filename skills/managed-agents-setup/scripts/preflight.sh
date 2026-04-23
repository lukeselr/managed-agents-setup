#!/usr/bin/env bash
# preflight.sh — Check prerequisites for Managed Agents setup.
# Outputs JSON status to stdout. Exits 0 even if checks fail — the driver agent decides.

set -u

STATE_DIR="$HOME/.claude/managed-agents"
mkdir -p "$STATE_DIR"

check() {
  if command -v "$1" >/dev/null 2>&1; then echo "true"; else echo "false"; fi
}

anthropic_key_present="false"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  anthropic_key_present="true"
elif security find-generic-password -a "$USER" -s "anthropic-managed-agents" -w >/dev/null 2>&1; then
  anthropic_key_present="true"
fi

ant_cli_installed=$(check ant)
python3_installed=$(check python3)
node_installed=$(check node)
jq_installed=$(check jq)
brew_installed=$(check brew)

python_sdk_installed="false"
if [ "$python3_installed" = "true" ]; then
  if python3 -c "import anthropic" >/dev/null 2>&1; then
    python_sdk_installed="true"
  fi
fi

typescript_sdk_installed="false"
if [ "$node_installed" = "true" ]; then
  if npm list -g --depth=0 2>/dev/null | grep -q "@anthropic-ai/sdk"; then
    typescript_sdk_installed="true"
  fi
fi

server_setup_detected="false"
secrets_env_path="null"
# Check Luke's server first, then generic ~/agents-cc locally
if [ -f "$HOME/agents-cc/shared/secrets.env" ]; then
  server_setup_detected="true"
  secrets_env_path="\"$HOME/agents-cc/shared/secrets.env\""
elif [ "${CHECK_SERVER:-0}" = "1" ] && command -v ssh >/dev/null 2>&1; then
  # Opt-in remote check. SSH ConnectTimeout alone is unreliable over Tailscale,
  # so also guard with a background-kill wall-clock timeout.
  ( ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
      -i ~/.ssh/clawd-key.pem ubuntu@100.119.119.120 \
      'test -f ~/agents-cc/shared/secrets.env' >/dev/null 2>&1 ) &
  SSH_PID=$!
  ( sleep 5 && kill -9 $SSH_PID 2>/dev/null ) &
  WATCHDOG_PID=$!
  if wait $SSH_PID 2>/dev/null; then
    server_setup_detected="true"
    secrets_env_path="\"ubuntu@100.119.119.120:~/agents-cc/shared/secrets.env\""
  fi
  kill $WATCHDOG_PID 2>/dev/null || true
fi

existing_vault_id="null"
if [ -f "$STATE_DIR/vault-id.txt" ]; then
  existing_vault_id="\"$(cat "$STATE_DIR/vault-id.txt")\""
fi

existing_env_id="null"
if [ -f "$STATE_DIR/env-id.txt" ]; then
  existing_env_id="\"$(cat "$STATE_DIR/env-id.txt")\""
fi

cat <<JSON
{
  "anthropic_key_present": $anthropic_key_present,
  "ant_cli_installed": $ant_cli_installed,
  "python3_installed": $python3_installed,
  "python_sdk_installed": $python_sdk_installed,
  "node_installed": $node_installed,
  "typescript_sdk_installed": $typescript_sdk_installed,
  "jq_installed": $jq_installed,
  "brew_installed": $brew_installed,
  "server_setup_detected": $server_setup_detected,
  "secrets_env_path": $secrets_env_path,
  "existing_vault_id": $existing_vault_id,
  "existing_env_id": $existing_env_id,
  "state_dir": "$STATE_DIR"
}
JSON
