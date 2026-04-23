#!/usr/bin/env bash
# install-everything.sh — Tier 2 TUI. Run ONE script, get a ready-to-use install.
# Wraps every prereq: Homebrew → node → python3 → ant → SDKs → gh → keychain key → workspace.
#
# Designed for the 45-year-old business owner at a Brisbane workshop.
# They double-click this, answer a few prompts, done.
set -u

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

ok()   { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1"; }
step() { echo -e "\n${BOLD}${BLUE}▸${NC} ${BOLD}$1${NC}"; }
ask()  { echo -e "\n${BOLD}$1${NC}"; read -rp "  > " REPLY; }

banner() {
cat <<'B'
╔════════════════════════════════════════════════════════════════╗
║                                                                ║
║         MANAGED AGENTS · ONE-COMMAND INSTALL                   ║
║                                                                ║
║         This sets up everything. No coding needed.             ║
║         You'll answer 3 questions. Takes ~10 minutes.          ║
║                                                                ║
╚════════════════════════════════════════════════════════════════╝
B
}

banner

# ═══ Homebrew ═══
step "Step 1 of 8: Homebrew (Mac package installer)"
if command -v brew >/dev/null 2>&1; then
  ok "Already installed ($(brew --version | head -1))"
else
  warn "Not found. Installing (you'll be asked for your Mac password)..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ok "Homebrew installed"
fi

# ═══ Dependencies ═══
step "Step 2 of 8: Required tools (node, python3, jq, gh)"
for bin in node python3 jq gh; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin"
  else
    case "$bin" in
      gh) brew install gh ;;
      *)  brew install "$bin" ;;
    esac
    ok "$bin installed"
  fi
done

# ═══ Anthropic SDKs ═══
step "Step 3 of 8: Anthropic SDKs (Python)"
if python3 -c "import anthropic" >/dev/null 2>&1; then
  ok "anthropic (python) already installed"
else
  python3 -m pip install --user --quiet anthropic httpx
  ok "anthropic SDK installed"
fi

# ═══ ant CLI ═══
step "Step 4 of 8: ant CLI (Anthropic command-line tool)"
if command -v ant >/dev/null 2>&1; then
  ok "ant CLI ($(ant --version 2>&1 | head -1))"
else
  brew tap anthropics/tap
  brew install anthropics/tap/ant
  xattr -d com.apple.quarantine "$(brew --prefix)/bin/ant" 2>/dev/null || true
  ok "ant installed"
fi

# ═══ Anthropic API Key ═══
step "Step 5 of 8: Anthropic API key"
if security find-generic-password -a "$USER" -s "anthropic-managed-agents" -w >/dev/null 2>&1; then
  ok "Key already in keychain"
else
  warn "No key found. Opening Anthropic console..."
  sleep 1
  open "https://platform.claude.com/settings/keys" 2>/dev/null
  echo ""
  echo "  In the browser:"
  echo "    1. Log in (or sign up if new)"
  echo "    2. Click 'Create API Key'"
  echo "    3. Copy the key (starts with sk-ant-)"
  echo ""
  read -rsp "  Paste the key here (nothing will show as you type): " KEY
  echo ""
  if [[ "$KEY" =~ ^sk-ant- ]]; then
    security add-generic-password -a "$USER" -s "anthropic-managed-agents" -w "$KEY" -U
    ok "Key saved to Mac keychain"
  else
    err "Doesn't look like an Anthropic key (should start with sk-ant-). Skipping."
  fi
fi

# Load into env
if security find-generic-password -a "$USER" -s "anthropic-managed-agents" -w >/dev/null 2>&1; then
  export ANTHROPIC_API_KEY="$(security find-generic-password -a "$USER" -s "anthropic-managed-agents" -w)"
fi

# ═══ Shell profile setup ═══
step "Step 6 of 8: Shell auto-load key on new terminal"
SHELL_RC="$HOME/.zshrc"
[ -f "$HOME/.bashrc" ] && SHELL_RC="$HOME/.bashrc"
if grep -q "anthropic-managed-agents" "$SHELL_RC" 2>/dev/null; then
  ok "Already configured in $SHELL_RC"
else
  cat >> "$SHELL_RC" <<RC

# Anthropic Managed Agents — auto-loaded by managed-agents-setup
if command -v security >/dev/null 2>&1; then
  export ANTHROPIC_API_KEY="\$(security find-generic-password -a "\$USER" -s anthropic-managed-agents -w 2>/dev/null)"
fi
RC
  ok "Added to $SHELL_RC"
fi

# ═══ Connector Wizard ═══
step "Step 7 of 8: Connect your apps (GHL, Gmail, Meta, Rube)"
ask "Run the connector wizard now? [Y/n]"
if [[ "${REPLY,,}" != "n" ]]; then
  bash "$(dirname "$0")/connector-wizard.sh"
fi

# ═══ Smoke test ═══
step "Step 8 of 8: Smoke test"
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  if curl -sS -f "https://api.anthropic.com/v1/models" \
       -H "x-api-key: $ANTHROPIC_API_KEY" \
       -H "anthropic-version: 2023-06-01" >/dev/null; then
    ok "API key works. Connected to Anthropic."
  else
    err "API call failed — check the key"
  fi
else
  warn "No API key set — skipping smoke test"
fi

echo ""
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}   INSTALL COMPLETE                                            ${NC}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Next step: create your first agent."
echo ""
echo "  bash ~/.claude/skills/managed-agents-setup/scripts/create-environment.sh primary"
echo "  bash ~/.claude/skills/managed-agents-setup/scripts/create-agent.sh rube-universal"
echo "  python3 ~/.claude/skills/managed-agents-setup/scripts/run-session.py \\"
echo "    --agent-id \"\$(cat ~/.claude/managed-agents/agents/rube-universal.txt)\" \\"
echo "    --env-id \"\$(cat ~/.claude/managed-agents/env-id.txt)\" \\"
echo "    --message 'Say hello'"
echo ""
echo "Questions? Luke is at @lukeselr on Instagram. Or share the log:"
echo "  bash ~/.claude/skills/managed-agents-setup/scripts/share-log.sh"
