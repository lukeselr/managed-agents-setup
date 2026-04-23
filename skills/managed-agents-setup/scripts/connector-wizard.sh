#!/usr/bin/env bash
# connector-wizard.sh — Tier 2 UX for workshop attendees.
# Detects empty secrets.env and walks the user through capturing tokens for
# the 3 most common services: GHL, Gmail (OAuth), Meta Ads.
#
# Output: fills ~/agents-cc/shared/secrets.env with values they actually have,
# so vault-seeder.py has something to seed. Without this, Phase 3 is empty.
#
# Usage:
#   bash connector-wizard.sh
set -u

SECRETS="${SECRETS_ENV:-$HOME/agents-cc/shared/secrets.env}"
mkdir -p "$(dirname "$SECRETS")"
touch "$SECRETS"
chmod 600 "$SECRETS"

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "   Connector Wizard — get your AI agents talking to your apps"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "I'll ask about 3 services. Skip any you don't use."
echo "Your API keys go into an encrypted vault — never touch code repos."
echo ""

# Helper: append or update a KEY=VALUE in secrets.env
set_secret() {
  local key="$1"
  local val="$2"
  [ -z "$val" ] && return 0
  # Remove existing entry
  sed -i.bak "/^export ${key}=/d" "$SECRETS" 2>/dev/null || true
  echo "export ${key}=\"${val}\"" >> "$SECRETS"
  echo "  [saved] ${key} (${#val} chars)"
}

prompt_secret() {
  local label="$1"
  local hint="$2"
  local varname="$3"
  echo ""
  echo "▸ $label"
  [ -n "$hint" ] && echo "  Hint: $hint"
  read -rsp "  Paste value (or Enter to skip): " val
  echo ""
  [ -n "$val" ] && set_secret "$varname" "$val" || echo "  [skip] $varname"
}

# ─ GHL ────────────────────────────────────────────────────────
echo "════ Step 1/3: GoHighLevel ════"
echo "Do you use GoHighLevel CRM? [y/N]"
read -r use_ghl
if [[ "${use_ghl,,}" == "y" ]]; then
  echo "Opening GHL settings page to grab your PIT (Private Integration Token)..."
  open "https://app.gohighlevel.com/settings/private_integrations" 2>/dev/null || \
    echo "  Open manually: https://app.gohighlevel.com/settings/private_integrations"
  echo "  Click 'Create' → give it scopes: contacts, opportunities, pipelines, conversations, campaigns"
  echo "  Copy the token (starts with 'pit-')"
  prompt_secret "GHL PIT Token" "pit-xxxxxxxxxxxxxxxxxxxxxxxx" "GHL_PIT_TOKEN"
  set_secret "GHL_API_KEY" "$(grep '^export GHL_PIT_TOKEN=' $SECRETS | sed 's/.*="\(.*\)"/\1/')"

  echo ""
  read -rp "  GHL Location ID (Settings > Business Profile > Location ID): " ghl_loc
  set_secret "GHL_LOCATION_ID" "$ghl_loc"
fi

# ─ Gmail / Google OAuth ───────────────────────────────────────
echo ""
echo "════ Step 2/3: Gmail + Calendar (Google) ════"
echo "Do you want agents to read/send from your Gmail? [y/N]"
read -r use_google
if [[ "${use_google,,}" == "y" ]]; then
  echo "Google requires OAuth (for security). This step is manual:"
  echo "  1. Open https://console.cloud.google.com/apis/credentials"
  echo "  2. Create OAuth 2.0 Client ID (Desktop app)"
  echo "  3. Download the credentials JSON"
  echo "  4. Paste the file path below"
  open "https://console.cloud.google.com/apis/credentials" 2>/dev/null || true
  read -rp "  Path to OAuth credentials JSON (or skip): " gpath
  if [ -n "$gpath" ] && [ -f "$gpath" ]; then
    mkdir -p ~/.claude/managed-agents/google
    cp "$gpath" ~/.claude/managed-agents/google/oauth-credentials.json
    set_secret "GOOGLE_OAUTH_CREDENTIALS_FILE" "$HOME/.claude/managed-agents/google/oauth-credentials.json"
    echo "  [saved] OAuth credentials stashed."
  else
    echo "  [skip] Google OAuth not configured (you can run the wizard again later)."
  fi
fi

# ─ Meta Ads ──────────────────────────────────────────────────
echo ""
echo "════ Step 3/3: Meta Ads (Facebook + Instagram) ════"
echo "Do you run Meta Ads? [y/N]"
read -r use_meta
if [[ "${use_meta,,}" == "y" ]]; then
  echo "Opening Meta Graph API Explorer to grab a long-lived token..."
  open "https://developers.facebook.com/tools/explorer/" 2>/dev/null || \
    echo "  Open manually: https://developers.facebook.com/tools/explorer/"
  echo "  1. Pick your app, click 'Generate Access Token'"
  echo "  2. Select scopes: ads_management, ads_read, business_management"
  echo "  3. Exchange it for a long-lived token (60 days min) at:"
  echo "     https://developers.facebook.com/tools/debug/accesstoken/"
  prompt_secret "Meta long-lived token" "60-day token" "META_ADS_TOKEN"
  read -rp "  Meta Ad Account ID (act_XXXXXXXXXX): " meta_acct
  set_secret "META_AD_ACCOUNT_ID" "$meta_acct"
fi

# ─ Rube (Composio) — always offer, it's the cheat code ───────
echo ""
echo "════ Bonus: Rube (Composio) — 500+ apps via ONE connection ════"
echo "Recommended for workshop attendees. One auth → HubSpot, Airtable, Stripe, Shopify, Slack, etc."
echo "Do you want to connect Rube? [Y/n]"
read -r use_rube
if [[ "${use_rube,,}" != "n" ]]; then
  echo "Opening rube.app..."
  open "https://rube.app/" 2>/dev/null || echo "  Open manually: https://rube.app/"
  echo "  1. Sign up with Google or GitHub"
  echo "  2. Connect the apps you use (1 click each)"
  echo "  3. Settings → API Keys → create one"
  prompt_secret "Composio API key" "comp_xxxxxxxx" "COMPOSIO_API_KEY"
fi

echo ""
echo "════ Wizard complete ════"
echo "Secrets stored in: $SECRETS (chmod 600)"
echo ""
echo "Next: run vault-seeder.py to push these into Anthropic Vault:"
echo "  python3 ~/.claude/skills/managed-agents-setup/scripts/vault-seeder.py \\"
echo "    --secrets-env $SECRETS --vault-name primary"
