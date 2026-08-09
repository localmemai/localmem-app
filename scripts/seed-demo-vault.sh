#!/usr/bin/env bash
#
# seed-demo-vault.sh — build the fictional vault used for marketing screenshots.
#
# Why this exists: screenshots used to be taken against the developer's own
# vault, which meant curating personal memories by hand before every capture and
# hoping nothing private crept into a PNG. Nobody wants that job, which is why
# web/screenshots/ went three weeks and six app-changing commits out of date.
#
# Everything below is invented. Nothing here is real, and nothing here touches
# the real vault: LOCALMEM_VAULT_DIR redirects the whole package (app, CLI, and
# MCP server) at a throwaway directory.
#
# Usage:
#   scripts/seed-demo-vault.sh [vault-dir]      # default: /tmp/localmem-demo-vault
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_DIR="${1:-/tmp/localmem-demo-vault}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

log "Building release binaries…"
swift build -c release --package-path "$REPO_ROOT" >/dev/null
BIN="$(swift build -c release --package-path "$REPO_ROOT" --show-bin-path)"

log "Resetting $VAULT_DIR"
rm -rf "$VAULT_DIR"
mkdir -p "$VAULT_DIR"
export LOCALMEM_VAULT_DIR="$VAULT_DIR"

lm() { "$BIN/localmem" "$@" >/dev/null; }
# `add --json` prints the created memory; grab its id for supersession edges.
lm_id() { "$BIN/localmem" add "$@" --json | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])'; }

# ---- folders ---------------------------------------------------------------
# Inbox exists by default. These give the sidebar something to show and make the
# "filed into folders" claim on the site true.
log "Creating folders…"
lm folder create "Personal"
lm folder create "localmem-app"
lm folder create "Acme Corp" --sensitive

# ---- personal ---------------------------------------------------------------
log "Adding memories…"
lm add "Drinks oat-milk flat whites." \
   --type preference --title "Coffee preference" --folder Personal \
   --tag coffee --tag drink --tag preference
lm add "Lives in Berlin; works CET hours." \
   --type fact --title "Berlin home base" --folder Personal \
   --tag location --tag timezone
lm add "Takes Fridays off. Don't schedule reviews or deploys then." \
   --type preference --title "Fridays off" --folder Personal \
   --tag schedule --tag availability
lm add "Prefers dark mode in every editor and terminal." \
   --type preference --title "Dark mode preference" --folder Personal \
   --tag editor --tag theme --tag preference

# ---- project ----------------------------------------------------------------
lm add "Analytics service reads from PostgreSQL, not the primary SQLite store." \
   --type decision --title "PostgreSQL for analytics service" --folder localmem-app \
   --tag database --tag architecture
lm add "Reviews happen in the morning, before any deploy goes out." \
   --type preference --title "Morning code reviews" --folder localmem-app \
   --tag workflow --tag review
lm add "Swift is the primary language; Python only for one-off scripts." \
   --type preference --title "Primary language is Swift" --folder localmem-app \
   --tag language --tag swift

# A superseded pair, so the detail pane shows a real supersession chain —
# the feature shipped in #32 and nothing on the site has ever shown it.
OLD_ID="$(lm_id "Staging deploys are run by hand before each release." \
   --type decision --title "Manual staging deploys" --folder localmem-app \
   --tag deploy --tag staging)"
NEW_ID="$(lm_id "Blue/green staging deploys, triggered automatically on merge to main." \
   --type decision --title "Blue/Green staging deploys" --folder localmem-app \
   --tag deploy --tag staging)"
lm supersede "$OLD_ID" --with "$NEW_ID"

# ---- sensitive ---------------------------------------------------------------
# The single most important frame on the site: a sensitive folder that a
# restricted agent cannot read. Nothing here resembles a real credential.
lm add "Acme's staging environment sits behind their VPN; access via the shared bastion." \
   --type fact --title "Acme staging access" --folder "Acme Corp" \
   --tag client --tag infrastructure
lm add "Acme contract comes up for renewal at the end of Q3." \
   --type project --title "Acme renewal timeline" --folder "Acme Corp" \
   --tag client --tag contract

# ---- agent visibility --------------------------------------------------------
# One restricted agent, so the Agents screen shows both states rather than a
# uniform column of "Allowed".
log "Setting agent visibility…"
lm agents set claude-code --all
lm agents set cursor --non-sensitive-only

COUNT="$("$BIN/localmem" list --limit 100 --json | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
log "Done. $COUNT memories in $VAULT_DIR"
