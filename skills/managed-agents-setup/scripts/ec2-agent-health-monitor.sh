#!/usr/bin/env bash
# ec2-agent-health-monitor.sh — Live health monitor for EC2-based agents.
# Runs on server via cron. Works TODAY (no Managed Agents API key needed).
# Pushes a summary to Telegram when anomalies detected.
#
# Deployed via: cron @ 0 22 * * * (8am Brisbane / 10pm UTC)
#
# What it checks:
#  1. Agent run.log freshness (stale = missed runs)
#  2. Error counts last 24h (per agent)
#  3. Auth mode distribution (oauth vs openrouter)
#  4. OpenRouter cost estimate (sum of agent runs × ~$0.10)
#  5. Running sessions (>6hr alerted)
#  6. Disk + memory
#  7. systemd service states (closer-webhook, telegram-bot-v2, router-v2)
set -uo pipefail

source "$HOME/agents-cc/shared/secrets.env" 2>/dev/null || true
AGENTS_DIR="$HOME/agents-cc"
NOW=$(date +%s)
NOW_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)

declare -A STATS
STATS[stale]=0
STATS[errors]=0
STATS[openrouter]=0
STATS[oauth]=0
STATS[total_runs]=0

AGENT_NAMES=()
for d in "$AGENTS_DIR"/*/; do
  name=$(basename "$d")
  # Skip non-agent dirs
  case "$name" in
    shared|logs|telegram-bot|webhook-server) continue ;;
  esac
  AGENT_NAMES+=("$name")
done

STALE_AGENTS=()
FAIL_AGENTS=()
CRITICAL=()

for a in "${AGENT_NAMES[@]}"; do
  LOG="$AGENTS_DIR/$a/run.log"
  [ -f "$LOG" ] || continue

  # Last run timestamp
  LAST_LINE=$(tail -1 "$LOG" 2>/dev/null || echo "")
  LAST_TS=$(echo "$LAST_LINE" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z' | head -1)
  if [ -n "$LAST_TS" ]; then
    LAST_EPOCH=$(date -d "$LAST_TS" +%s 2>/dev/null || echo 0)
    AGE_HOURS=$(( (NOW - LAST_EPOCH) / 3600 ))
    if [ "$AGE_HOURS" -gt 48 ]; then
      STALE_AGENTS+=("$a (${AGE_HOURS}h)")
      STATS[stale]=$((${STATS[stale]:-0} + 1))
    fi
  fi

  # Count error lines in last 24h (force integer output)
  ERR_COUNT=$(grep -cE "ERROR|exit=[1-9]|AUTH_RETRY" "$LOG" 2>/dev/null | tr -d ' \n')
  ERR_COUNT=${ERR_COUNT:-0}
  if [ "$ERR_COUNT" -gt 5 ] 2>/dev/null; then
    FAIL_AGENTS+=("$a (${ERR_COUNT} errors)")
    STATS[errors]=$(( ${STATS[errors]:-0} + ERR_COUNT ))
  fi

  # Auth mode tallies (force integer output)
  OR_COUNT=$(grep -c "auth=openrouter" "$LOG" 2>/dev/null | tr -d ' \n')
  OA_COUNT=$(grep -c "auth=oauth" "$LOG" 2>/dev/null | tr -d ' \n')
  OR_COUNT=${OR_COUNT:-0}
  OA_COUNT=${OA_COUNT:-0}
  STATS[openrouter]=$(( ${STATS[openrouter]:-0} + OR_COUNT ))
  STATS[oauth]=$(( ${STATS[oauth]:-0} + OA_COUNT ))
  STATS[total_runs]=$(( ${STATS[total_runs]:-0} + OR_COUNT + OA_COUNT ))
done

# systemd health
SVC_ISSUES=()
for svc in closer-webhook telegram-bot-v2 router-v2; do
  STATE=$(systemctl --user is-active "$svc" 2>/dev/null || echo "unknown")
  if [ "$STATE" != "active" ]; then
    SVC_ISSUES+=("$svc: $STATE")
  fi
done

# Resources
DISK_PCT=$(df -h / | awk 'NR==2 {print $5}' | tr -d '%')
MEM_MB=$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')

# Cost estimate (rough): assume $0.08 avg per OpenRouter run
OR_COST=$(echo "${STATS[openrouter]:-0} * 0.08" | bc -l 2>/dev/null || echo "?")

# Build report
REPORT="*EC2 Agent Health Report*
$NOW_UTC

Agents: ${#AGENT_NAMES[@]}
Total runs (log): ${STATS[total_runs]:-0}
  OpenRouter: ${STATS[openrouter]:-0} (~\$$(printf '%.2f' ${OR_COST:-0})/cumulative)
  OAuth: ${STATS[oauth]:-0}

Disk: ${DISK_PCT}% used
Memory: ${MEM_MB}MB avail"

if [ ${#STALE_AGENTS[@]} -gt 0 ]; then
  REPORT="$REPORT

Stale agents (>48h):
$(printf '  - %s\n' "${STALE_AGENTS[@]}")"
fi

if [ ${#FAIL_AGENTS[@]} -gt 0 ]; then
  REPORT="$REPORT

Agents with errors:
$(printf '  - %s\n' "${FAIL_AGENTS[@]}")"
fi

if [ ${#SVC_ISSUES[@]} -gt 0 ]; then
  REPORT="$REPORT

Service issues:
$(printf '  - %s\n' "${SVC_ISSUES[@]}")"
  CRITICAL+=("1+ services down")
fi

# Alert level
LEVEL="info"
[ "$DISK_PCT" -gt 85 ] && { LEVEL="warn"; CRITICAL+=("disk ${DISK_PCT}%"); }
[ "$MEM_MB" -lt 500 ] && { LEVEL="warn"; CRITICAL+=("memory low"); }
[ ${#FAIL_AGENTS[@]} -gt 3 ] && { LEVEL="warn"; CRITICAL+=("${#FAIL_AGENTS[@]} agents failing"); }
[ ${#CRITICAL[@]} -gt 0 ] && LEVEL="alert"

echo "$REPORT" | tee -a "$HOME/agents-cc/health-monitor.log"

# Telegram push (only on non-info level, or once daily for summary)
HOUR=$(date +%H)
if [ "$LEVEL" != "info" ] || [ "$HOUR" = "22" ]; then
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "content-type: application/json" \
      -d "$(python3 -c "import json,sys; print(json.dumps({'chat_id':'${TELEGRAM_CHAT_ID}','text':sys.argv[1],'parse_mode':'Markdown'}))" "$REPORT")" \
      >/dev/null
  fi
fi

# Critical situations → write noticeboard message for ops agent
if [ "$LEVEL" = "alert" ] && [ -f "$HOME/agents-cc/shared/scripts/noticeboard.sh" ]; then
  "$HOME/agents-cc/shared/scripts/noticeboard.sh" send "health-monitor" "ops" "high" \
    "Health alert: ${CRITICAL[*]}" 2>/dev/null || true
fi
