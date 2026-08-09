#!/usr/bin/env bash
#
# capture-window.sh — screenshot one window of a running app, by owner name.
#
# scripts/screenshots.sh drives the Localmem app itself; this is for windows
# nothing can script — a terminal running Claude Code, say, where the agent's
# reply is not reproducible and the run has to be done by hand.
#
# Requires Screen Recording permission, and must be run from a terminal with a
# UI: a request from a windowless helper fails silently instead of prompting.
#
# Usage:
#   scripts/capture-window.sh <owner> <output.png> [min-width] [max-width]
#
# Examples:
#   scripts/capture-window.sh Terminal web/screenshots/agent-claude-code.png
#   scripts/capture-window.sh iTerm2 /tmp/shot.png 900
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ $# -lt 2 ]; then
	sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
	exit 64
fi

OWNER="$1"
OUTPUT="$2"
MIN_WIDTH="${3:-380}"
MAX_WIDTH="${4:-}"

# Give yourself time to bring the target window forward and get your cursor out
# of the frame.
DELAY="${DELAY:-4}"
printf 'Capturing "%s" in %ss — bring that window to the front now…\n' "$OWNER" "$DELAY"
sleep "$DELAY"

# shellcheck disable=SC2086
if ! read -r wid width height < <(swift "$REPO_ROOT/scripts/windowid.swift" "$OWNER" "$MIN_WIDTH" $MAX_WIDTH); then
	echo "error: no on-screen window owned by \"$OWNER\"." >&2
	echo "       Owner names come from the process, not the app menu — try: Terminal, iTerm2, Code." >&2
	exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"
if ! screencapture -l"$wid" -o -x "$OUTPUT"; then
	cat >&2 <<-'EOF'
		error: screencapture could not read the window.

		This is the Screen Recording permission, not a bug. Open
		  System Settings → Privacy & Security → Screen & System Audio Recording
		enable the terminal you are running this from, quit it completely, reopen,
		and try again.
	EOF
	exit 1
fi

echo "Wrote $OUTPUT (${width}x${height} points)"
