#!/usr/bin/env bash
# install-log-lib.sh — Shared logging helper for managed-agents-setup scripts.
# Source this at the top of every script to get structured JSON logs + a share-ID at the end.
#
# Usage (inside another script):
#   source "$(dirname "$0")/install-log-lib.sh"
#   log_phase "preflight" "starting"
#   log_info  "preflight" "ant CLI present" '{"version":"1.0.0"}'
#   log_error "preflight" "ant missing" '{"hint":"brew install"}'

INSTALL_LOG_DIR="${INSTALL_LOG_DIR:-$HOME/.claude/managed-agents}"
INSTALL_LOG_FILE="$INSTALL_LOG_DIR/install.log"
mkdir -p "$INSTALL_LOG_DIR"

_log_emit() {
  local level="$1"; shift
  local phase="$1"; shift
  local msg="$1"; shift
  local extras="${1:-{}}"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"ts":"%s","level":"%s","phase":"%s","msg":"%s","extras":%s}\n' \
    "$ts" "$level" "$phase" "${msg//\"/\\\"}" "$extras" >> "$INSTALL_LOG_FILE"
  # Also echo to stderr for human visibility, colorless for reliability
  printf '[%s][%s] %s\n' "$level" "$phase" "$msg" >&2
}

log_phase() { _log_emit "phase" "$1" "${2:-}" '{}'; }
log_info()  { _log_emit "info"  "$1" "$2" "${3:-{}}"; }
log_warn()  { _log_emit "warn"  "$1" "$2" "${3:-{}}"; }
log_error() { _log_emit "error" "$1" "$2" "${3:-{}}"; }

export -f _log_emit log_phase log_info log_warn log_error
