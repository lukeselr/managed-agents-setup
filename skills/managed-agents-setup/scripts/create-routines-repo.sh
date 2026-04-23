#!/usr/bin/env bash
# create-routines-repo.sh — Tier 2 UX.
# Creates a private GitHub repo with .claude/ config so attendees can use Routines.
# Without a repo, Routines won't run (they git-clone a repo on each fire).
#
# Usage:
#   bash create-routines-repo.sh [repo-name]
set -euo pipefail

REPO_NAME="${1:-claude-routines}"
PARENT_DIR="${PARENT_DIR:-$HOME}"

if ! command -v gh >/dev/null 2>&1; then
  echo "[fatal] gh CLI required. Install: brew install gh"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "[info] Not logged into gh. Running: gh auth login"
  gh auth login
fi

cd "$PARENT_DIR"
if [ -d "$REPO_NAME" ]; then
  echo "[skip] ~/$REPO_NAME already exists."
else
  echo "[init] Creating ~/$REPO_NAME/"
  mkdir -p "$REPO_NAME"
  cd "$REPO_NAME"
  git init -q
  git branch -M main
fi

cd "$PARENT_DIR/$REPO_NAME"

# Seed .claude/CLAUDE.md
mkdir -p .claude
if [ ! -f .claude/CLAUDE.md ]; then
  cat > .claude/CLAUDE.md <<'CLAUDE'
# Routine Environment

This repo is the working directory for Claude Code Routines (cloud scheduled tasks).

When a routine fires, Claude Code clones this repo and runs with this as context.

## Available Tools
- Bash, Read, Write, Edit, Glob, Grep, Task
- MCP servers declared in `.mcp.json`

## Writing Back
Committing changes to this repo writes back to your GitHub. Push only to `claude/*` branches
unless you've enabled unrestricted pushes in routine settings.

## Memory
Session logs appear in `./logs/` after each run.
CLAUDE
fi

# Seed .mcp.json — empty shell, filled by vault/bridge
if [ ! -f .mcp.json ]; then
  cat > .mcp.json <<'MCP'
{
  "mcpServers": {}
}
MCP
fi

# .gitignore
if [ ! -f .gitignore ]; then
  cat > .gitignore <<'GI'
# Secrets — NEVER commit
.env
.env.*
secrets.env
*.pem
*.key
credentials.*
__pycache__/
*.pyc
.DS_Store
GI
fi

# README
if [ ! -f README.md ]; then
  cat > README.md <<README
# claude-routines

Working directory for Claude Code Routines (scheduled cloud tasks).

Managed by managed-agents-setup skill.

## Structure
- \`.claude/CLAUDE.md\` — routine context
- \`.mcp.json\` — MCP server declarations
- \`logs/\` — session outputs

Do not commit secrets. The vault on Anthropic holds all credentials.
README
fi

git add .
git commit -q -m "Init routines repo from managed-agents-setup" 2>/dev/null || echo "[info] Nothing to commit"

# Create on GitHub (private by default)
if ! gh repo view "$REPO_NAME" >/dev/null 2>&1; then
  echo "[gh] Creating private repo $REPO_NAME..."
  gh repo create "$REPO_NAME" --private --source=. --push
else
  echo "[gh] Repo exists, pushing..."
  git push -u origin main 2>/dev/null || true
fi

USER=$(gh api user -q .login)
URL="https://github.com/$USER/$REPO_NAME"

echo ""
echo "════ Routines repo ready ════"
echo "  Local:  $PARENT_DIR/$REPO_NAME"
echo "  Remote: $URL"
echo ""
echo "Next: when creating a routine, use this URL as the Git repository:"
echo "  $URL"
