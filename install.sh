#!/usr/bin/env bash
# install.sh — bootstrapper for managed-agents-setup
#
# Fetches the skill into ~/.claude/skills/managed-agents-setup/
# then runs scripts/install-everything.sh
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/lukeselr/managed-agents-setup/main/install.sh | bash
#
# Idempotent: re-running updates the clone + reruns the installer.

set -euo pipefail

VERSION="1.0.0"
REPO_URL="${MAS_REPO_URL:-https://github.com/lukeselr/managed-agents-setup.git}"
BRANCH="${MAS_BRANCH:-main}"
SKILL_DIR="${MAS_SKILL_DIR:-$HOME/.claude/skills/managed-agents-setup}"

red()    { printf '\033[31m%s\033[0m\n' "$*"; }
green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[34m%s\033[0m\n' "$*"; }

# ---------- safety ----------
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  red "[abort] Do not run this with sudo. The skill installs into \$HOME, which should be your own user."
  exit 1
fi

if [[ "${CI:-}" == "true" ]]; then
  yellow "[warn] CI detected. Skipping interactive post-install. Set MAS_NONINTERACTIVE=1 to silence."
  export MAS_NONINTERACTIVE=1
fi

# ---------- prereqs ----------
for cmd in git bash; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    red "[abort] Missing required command: $cmd"
    exit 1
  fi
done

OS="$(uname -s)"
case "$OS" in
  Darwin) ;;
  Linux)  yellow "[warn] Linux is untested. macOS is the supported platform." ;;
  *)      red "[abort] Unsupported OS: $OS"; exit 1 ;;
esac

# ---------- banner ----------
blue "============================================================"
blue " managed-agents-setup  v$VERSION"
blue " Zero-to-production Anthropic Managed Agents + Routines"
blue "============================================================"

# ---------- fetch ----------
mkdir -p "$(dirname "$SKILL_DIR")"

if [[ -d "$SKILL_DIR/.git" ]]; then
  green "[update] Existing install at $SKILL_DIR — pulling latest"
  git -C "$SKILL_DIR" fetch --quiet origin "$BRANCH"
  git -C "$SKILL_DIR" reset --hard "origin/$BRANCH" --quiet
elif [[ -d "$SKILL_DIR" ]]; then
  yellow "[move] $SKILL_DIR exists but is not a git repo — backing up to $SKILL_DIR.bak.$(date +%s)"
  mv "$SKILL_DIR" "$SKILL_DIR.bak.$(date +%s)"
  git clone --depth 1 --branch "$BRANCH" --quiet "$REPO_URL" "$SKILL_DIR"
else
  green "[clone] Fetching skill to $SKILL_DIR"
  git clone --depth 1 --branch "$BRANCH" --quiet "$REPO_URL" "$SKILL_DIR"
fi

# ---------- permissions ----------
chmod +x "$SKILL_DIR/scripts/"*.sh 2>/dev/null || true

# ---------- handoff ----------
green "[ok] Skill installed at $SKILL_DIR"
echo
blue "Launching install-everything.sh..."
echo

exec "$SKILL_DIR/scripts/install-everything.sh" "$@"
