#!/usr/bin/env bash
# mcp-bridge.sh — Push local Claude Code MCP configs into Managed Agents vaults.
#
# Reads: ~/.claude/skills/managed-agents-setup/references/mcp-bridge.json
# Writes: ~/.claude/managed-agents/bridge-log.json (idempotent)
# Depends: jq, anthropic CLI (installed via install-cli.sh), security (macOS keychain)
#
# Usage:
#   ./mcp-bridge.sh --vault <vault_id> [--only <mcp_name>] [--dry-run] [--category A|B|C|D]
#
# Behavior:
#   A (auto-transferable): pulls token, pushes to vault via `anthropic agents vaults update`
#   B (OAuth required):   prints the OAuth URL + one-shot command for the user
#   C (stdio/local only): logs "stays local"
#   D (redundant):        logs "covered by Rube, skipping"

set -euo pipefail

MANIFEST="~/.claude/skills/managed-agents-setup/references/mcp-bridge.json"
LOG_DIR="$HOME/.claude/managed-agents"
LOG_FILE="$LOG_DIR/bridge-log.json"
SECRETS_ENV="$HOME/.claude/managed-agents/secrets.env"
VAULT_ID=""
ONLY=""
DRY_RUN=false
CATEGORY_FILTER=""

mkdir -p "$LOG_DIR"
[[ -f "$LOG_FILE" ]] || echo '{"runs":[]}' > "$LOG_FILE"

# ---- arg parse ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vault) VAULT_ID="$2"; shift 2;;
    --only) ONLY="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift;;
    --category) CATEGORY_FILTER="$2"; shift 2;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0;;
    *) echo "Unknown flag: $1"; exit 1;;
  esac
done

[[ -z "$VAULT_ID" ]] && { echo "ERROR: --vault <vault_id> required"; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq required (brew install jq)"; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "ERROR: manifest missing at $MANIFEST"; exit 1; }

# Load optional secrets file (never committed)
# shellcheck disable=SC1090
[[ -f "$SECRETS_ENV" ]] && source "$SECRETS_ENV"

RUN_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_RESULTS="[]"

log_result() {
  local name="$1" status="$2" category="$3" note="$4"
  RUN_RESULTS=$(jq --arg n "$name" --arg s "$status" --arg c "$category" --arg m "$note" \
    '. += [{"name":$n,"status":$s,"category":$c,"note":$m}]' <<<"$RUN_RESULTS")
  printf "  [%s] %-32s %s — %s\n" "$category" "$name" "$status" "$note"
}

# ---- pull helpers ----
keychain_get() {
  # keychain_get <account>
  security find-generic-password -a "$1" -w 2>/dev/null || true
}

resolve_token() {
  # resolve_token "<source_spec>"  → prints token or empty
  local spec="$1" token=""
  IFS='|' read -ra SOURCES <<<"$spec"
  for src in "${SOURCES[@]}"; do
    src="$(echo "$src" | xargs)"  # trim
    case "$src" in
      inline:*)
        # handled inline by jq in main loop, not here
        continue ;;
      keychain:*)
        token="$(keychain_get "${src#keychain:}")"
        ;;
      env:*)
        token="${!src#env:}" || token=""
        ;;
      oauth_flow|none|*)
        continue ;;
    esac
    [[ -n "$token" ]] && { echo "$token"; return 0; }
  done
  echo ""
}

# ---- vault push ----
push_vault_entry() {
  # push_vault_entry <key> <json_payload>
  local key="$1" payload="$2"
  if $DRY_RUN; then
    echo "    DRY-RUN would push $key → vault $VAULT_ID: $(echo "$payload" | jq -c .)"
    return 0
  fi
  # Idempotent: upsert via anthropic CLI (managed-agents)
  anthropic agents vaults update "$VAULT_ID" --secret-key "$key" --secret-json "$payload" 2>&1 \
    || { echo "    WARN: vault push failed for $key"; return 1; }
}

# ---- main loop ----
echo "mcp-bridge: vault=$VAULT_ID dry_run=$DRY_RUN filter=${CATEGORY_FILTER:-all} only=${ONLY:-all}"
echo "manifest:  $MANIFEST"
echo

# iterate all entries except _meta
jq -r 'to_entries[] | select(.key != "_meta") | .key' "$MANIFEST" | while read -r name; do
  [[ -n "$ONLY" && "$name" != "$ONLY" ]] && continue
  entry="$(jq --arg k "$name" '.[$k]' "$MANIFEST")"
  category="$(echo "$entry" | jq -r '.category')"
  [[ -n "$CATEGORY_FILTER" && "$category" != "$CATEGORY_FILTER" ]] && continue

  ma_url="$(echo "$entry" | jq -r '.ma_url // empty')"
  auth_type="$(echo "$entry" | jq -r '.auth_type // empty')"
  token_source="$(echo "$entry" | jq -r '.local_token_source // empty')"
  notes="$(echo "$entry" | jq -r '.notes // ""')"
  rube_covers="$(echo "$entry" | jq -r '.rube_covers // false')"

  case "$category" in
    D)
      log_result "$name" "SKIPPED" "D" "redundant — covered by Rube"
      continue ;;
    C)
      log_result "$name" "LOCAL-ONLY" "C" "stdio only, stays on Mac"
      continue ;;
    B)
      # OAuth one-shot instructions
      echo
      echo "  === $name (OAuth required) ==="
      echo "  1. Run:  anthropic agents vaults connect-oauth $VAULT_ID --mcp $name --url $ma_url"
      echo "  2. Browser opens. Authorize. Paste code back in terminal."
      echo "  3. Rerun this script — it will confirm connection and skip this entry."
      log_result "$name" "OAUTH-PROMPTED" "B" "user action required: see instructions above"
      continue ;;
    A)
      # Auto-transferable
      if [[ -z "$ma_url" ]]; then
        log_result "$name" "BLOCKED" "A" "no ma_url in manifest — flag for review"
        continue
      fi

      token=""
      # inline resolution first (token embedded in .claude.json)
      if [[ "$token_source" == inline:* ]]; then
        case "$name" in
          gohighlevel-official)
            token="$(jq -r '.mcpServers["ghl-official"].headers.Authorization | sub("^Bearer "; "")' ~/.claude.json 2>/dev/null)"
            ;;
          supabase-agents)
            token="$(jq -r '.projects["<YOUR_HOME>"].mcpServers.supabase.args[4]' ~/.claude.json 2>/dev/null)"
            ;;
          framer)
            token="url-embedded"  # no separate token
            ;;
          meta-ads)
            token="$(jq -r '.mcpServers["meta-ads"].env.META_ACCESS_TOKEN' ~/.mcp.json 2>/dev/null)"
            ;;
          n8n)
            token="$(jq -r '.mcpServers.n8n.env.N8N_API_KEY' ~/.claude/projects/<YOUR_PROJECT_KEY>/.mcp.json 2>/dev/null)"
            ;;
        esac
      fi

      # fallback: keychain / env chain
      if [[ -z "$token" || "$token" == "null" ]]; then
        token="$(resolve_token "$token_source")"
      fi

      if [[ -z "$token" || "$token" == "null" ]]; then
        log_result "$name" "MISSING-TOKEN" "A" "token not in keychain/env/inline — add to $SECRETS_ENV"
        continue
      fi

      # Build vault payload
      extra_headers="$(echo "$entry" | jq -c '.extra_headers // {}')"
      if [[ "$name" == "framer" ]]; then
        payload=$(jq -cn --arg url "$ma_url" '{type:"url_embedded", mcp_server_url:$url}')
      else
        payload=$(jq -cn \
          --arg url "$ma_url" \
          --arg token "$token" \
          --argjson headers "$extra_headers" \
          '{type:"static_bearer", mcp_server_url:$url, token:$token, extra_headers:$headers}')
      fi

      if push_vault_entry "$name" "$payload"; then
        log_result "$name" "PUSHED" "A" "url=$ma_url headers=$(echo "$extra_headers" | jq -c 'keys')"
      else
        log_result "$name" "ERROR" "A" "vault CLI failed — see stderr"
      fi
      ;;
    *)
      log_result "$name" "UNKNOWN" "?" "missing category"
      ;;
  esac
done

# ---- persist run to log ----
TMP="$(mktemp)"
jq --arg ts "$RUN_TS" --arg vault "$VAULT_ID" --argjson results "$RUN_RESULTS" \
  '.runs += [{"ts":$ts,"vault":$vault,"results":$results}]' "$LOG_FILE" > "$TMP"
mv "$TMP" "$LOG_FILE"

echo
echo "Done. Log appended: $LOG_FILE"
echo "Summary:"
echo "$RUN_RESULTS" | jq -r '.[] | "  \(.status)\t\(.category)\t\(.name)"' | sort | uniq -c | sort -rn
