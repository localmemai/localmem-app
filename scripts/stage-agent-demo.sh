#!/usr/bin/env bash
#
# stage-agent-demo.sh — set up a scratch project where Claude Code talks to the
# demo vault, for capturing "an agent recalling your context" screenshots.
#
# Why only Claude Code: it is the one client of the three that supports a
# project-scoped `.mcp.json`. Codex (~/.codex/config.toml) and Antigravity
# (~/.gemini/config/mcp_config.json) are configured globally, so staging them
# means either redirecting their whole config directory — which separates them
# from the credentials they need to log in — or editing the config you actually
# use and restoring it afterwards. Neither is worth the risk for a marketing
# image.
#
# The session itself is manual. An agent's wording is not reproducible, so this
# script stages everything around the run and gets out of the way.
#
# Usage:
#   scripts/stage-agent-demo.sh [project-dir]     # default /tmp/localmem-demo-project
#   scripts/stage-agent-demo.sh --no-seed [dir]   # keep the existing demo vault
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEED=1
if [ "${1:-}" = "--no-seed" ]; then SEED=0; shift; fi
PROJECT_DIR="${1:-/tmp/localmem-demo-project}"
VAULT_DIR="${LOCALMEM_VAULT_DIR:-/tmp/localmem-demo-vault}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

if [ "$SEED" = "1" ]; then
	"$REPO_ROOT/scripts/seed-demo-vault.sh" "$VAULT_DIR"
fi

swift build -c release --package-path "$REPO_ROOT" >/dev/null
BIN="$(swift build -c release --package-path "$REPO_ROOT" --show-bin-path)"
MCP_BIN="$BIN/localmem-mcp"

log "Staging $PROJECT_DIR"
rm -rf "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR"

# Project-scoped MCP config. Claude Code discovers this from the working
# directory, so ~/.claude.json is never touched.
cat >"$PROJECT_DIR/.mcp.json" <<EOF
{
  "mcpServers": {
    "localmem": {
      "command": "$MCP_BIN",
      "env": { "LOCALMEM_VAULT_DIR": "$VAULT_DIR" }
    }
  }
}
EOF

# A shell with nothing personal in the prompt. The default prompt carries the
# username and hostname, which should not be in a published screenshot.
cat >"$PROJECT_DIR/.demo-rc" <<'EOF'
PS1='~/demo % '
# 30 rows x 100 columns, so frames match each other.
printf '\e[8;30;100t'
clear
EOF

# One command, absolute paths, both flags. Typing this by hand is how the first
# two attempts ended up talking to the real vault: a project .mcp.json does not
# displace a user-scope server, and a mistyped `cd` leaves you in a directory
# with no project config at all — in both cases the agent connects to the real
# vault and simply reports finding nothing.
cat >"$PROJECT_DIR/run-demo.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "$PROJECT_DIR"
exec claude --strict-mcp-config --mcp-config "$PROJECT_DIR/.mcp.json"
EOF
chmod +x "$PROJECT_DIR/run-demo.sh"

log "Done."
cat <<EOF

Vault:   $VAULT_DIR
Project: $PROJECT_DIR

1. Open Terminal (not an IDE — capture needs Screen Recording, and only an
   app with a UI gets prompted for it) and start a clean shell:

     cd $PROJECT_DIR && bash --rcfile .demo-rc

2. Launch the agent — use the launcher, not \`claude\` directly:

     $PROJECT_DIR/run-demo.sh

   It carries both required flags and absolute paths. A project .mcp.json
   does not displace the localmem server already registered at user scope,
   so plain \`claude\` connects to your real vault; --strict-mcp-config
   ignores every other MCP configuration, without editing the config you
   use daily.

   Confirm before capturing: ask about "Acme staging" — that memory exists
   only in the demo vault. Empty results mean you are on the real one, and
   the agent will say so calmly rather than erroring.

3. Give it a prompt that forces a recall, e.g.

     What do you know about my coffee preference?

4. Capture the terminal window:

     $REPO_ROOT/scripts/capture-window.sh Terminal web/screenshots/agent-claude-code.png

Before capturing, check the frame for anything you would rather not publish:
the working directory in the prompt, and whatever Claude Code shows in its own
footer.

Running a real session also fixes two app screenshots: the demo vault is
CLI-seeded today, so the status bar reads "Connected Agents: None" and
overview.png lists CLI writes under "Recent Agent Activity". After a genuine
agent session against this vault, both become real. Re-run
scripts/screenshots.sh --no-seed afterwards to pick that up.
EOF
