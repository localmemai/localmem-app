#!/usr/bin/env bash
#
# screenshots.sh — regenerate web/screenshots/*.png from a seeded demo vault.
#
# Requires Screen Recording permission for the terminal you run this from.
# macOS prompts on the first capture attempt; grant it, then rerun. Run from
# Terminal.app or iTerm — a capture requested by a windowless background helper
# fails silently with "could not create image from window" instead of prompting.
#
# Usage:
#   scripts/screenshots.sh                 # seed a fresh vault, then capture
#   scripts/screenshots.sh --no-seed       # reuse the existing demo vault
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_DIR="${LOCALMEM_VAULT_DIR:-/tmp/localmem-demo-vault}"
OUT_DIR="$REPO_ROOT/web/screenshots"
APPEARANCE="${LOCALMEM_APPEARANCE:-light}"
# Seconds to wait for the window to appear and the first data poll to land.
SETTLE="${SETTLE:-6}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

if [ "${1:-}" != "--no-seed" ]; then
	"$REPO_ROOT/scripts/seed-demo-vault.sh" "$VAULT_DIR"
fi

swift build -c release --package-path "$REPO_ROOT" >/dev/null
BIN="$(swift build -c release --package-path "$REPO_ROOT" --show-bin-path)"
mkdir -p "$OUT_DIR"

# name:env-assignments — the app's existing screenshot hooks
# (LOCALMEM_INITIAL_SECTION, LOCALMEM_SHOW_WIZARD, LOCALMEM_APPEARANCE) pin the
# state, so nothing here has to click anything.
#
# The vault shot opens the coffee memory on purpose: the terminal panel higher
# up the page shows an agent recalling that same fact, so the two carousels tell
# one story instead of two.
#
# Third field is an optional "min-width max-width" pair, used to pick the right
# window once a shot opens more than one.
SHOTS=(
	"vault:LOCALMEM_INITIAL_SECTION=memories LOCALMEM_SELECT_TITLE=Coffee:900"
	"overview:LOCALMEM_INITIAL_SECTION=overview:900"
	"agents:LOCALMEM_INITIAL_SECTION=agents:900"
	"activity:LOCALMEM_INITIAL_SECTION=audit:900"
	"connectors:LOCALMEM_INITIAL_SECTION=connectors:900"
	"setup:LOCALMEM_SHOW_WIZARD=1:900"
	"settings:LOCALMEM_INITIAL_SECTION=overview LOCALMEM_SHOW_SETTINGS=1:380 600"
)

capture_one() {
	local name="$1" assignment="$2" title="${3:-}"
	# Braces are load-bearing: the ellipsis is multibyte, and bash reads its
	# bytes as part of an unbraced variable name.
	log "Capturing ${name}…"

	# `assignment` may carry several VAR=VALUE pairs; word-splitting is wanted.
	# shellcheck disable=SC2086
	env LOCALMEM_VAULT_DIR="$VAULT_DIR" LOCALMEM_APPEARANCE="$APPEARANCE" \
		$assignment "$BIN/localmem-app" >/dev/null 2>&1 &
	local app_pid=$!
	# Drop it from the job table so killing it later doesn't print
	# "Terminated: 15", which reads like a failure in the output.
	disown "$app_pid" 2>/dev/null || true
	sleep "$SETTLE"

	local wid width height
	# shellcheck disable=SC2086
	if ! read -r wid width height < <(swift "$REPO_ROOT/scripts/windowid.swift" localmem-app $title); then
		kill "$app_pid" 2>/dev/null || true
		echo "error: no window found for $name" >&2
		return 1
	fi

	# -o drops the drop shadow, so slides butt up against their frame cleanly.
	if ! screencapture -l"$wid" -o -x "$OUT_DIR/$name.png"; then
		kill "$app_pid" 2>/dev/null || true
		cat >&2 <<-'EOF'
			error: screencapture could not read the window.

			This is the Screen Recording permission, not a bug. Open
			  System Settings → Privacy & Security → Screen & System Audio Recording
			enable the terminal you are running this from, quit it completely, reopen,
			and run this script again.
		EOF
		return 1
	fi

	kill "$app_pid" 2>/dev/null || true
	wait "$app_pid" 2>/dev/null || true
	echo "    ${name}.png  (${width}x${height} points)"
}

for shot in "${SHOTS[@]}"; do
	IFS=':' read -r shot_name shot_env shot_title <<<"$shot"
	capture_one "$shot_name" "$shot_env" "$shot_title"
done

log "Done. Wrote $(ls -1 "$OUT_DIR"/*.png | wc -l | tr -d ' ') files to web/screenshots/"
cat <<'EOF'

Next: the <img> tags in web/index.html carry explicit width/height. If the
window size changed, update them to match, or the carousel will letterbox.
EOF
