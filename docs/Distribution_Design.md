# Distribution & Download — Design

Status: Proposed · Author: design discussion 2026-07-02 · Scope: packaging, website, release pipeline · Platform: **macOS only**

## Goal

Decide how users get Localmem onto their Mac. Two audiences:

1. **Terminal / power users** who want only the command-line tool, installed the
   way they install every other dev tool (Homebrew).
2. **App users** who visit the website, click a download button, and get the GUI
   app — which also carries the command-line tool with it.

This doc lays out every viable channel, the constraints that rule some out, a
recommended shape, and the open decisions to settle.

> **Platform note:** Localmem is a macOS-only product. There is no Windows or
> Linux launch. Every option below is macOS-native; no cross-platform installer
> (MSI, winget, apt) is in scope.

## What we're shipping

Localmem is three binaries that must travel together:

| Binary | Role |
|---|---|
| `localmem-app` | The SwiftUI GUI (vault, agents, setup wizard) |
| `localmem` | The command-line tool (`localmem setup`, `add`, `search`, …) |
| `localmem-mcp` | The MCP server the AI clients actually talk to |

## Core constraints (these dictate the design)

1. **The MCP server needs a stable, absolute path.** When setup registers
   Localmem with Claude Code, Claude Desktop, Cursor, Codex, and Antigravity, it
   writes the *absolute path* of `localmem-mcp` into each client's config. If
   that path later moves, every client silently breaks. `localmem-mcp` is located
   as a **sibling of the running binary**, so the three binaries must be
   co-located and must stay put.

2. **Everything must be code-signed and notarized.** Any binary distributed
   outside the Mac App Store — DMG, zip, pkg, Homebrew bottle, or a curl'd
   binary — is checked by macOS Gatekeeper. Without an Apple **Developer ID**
   signature and **notarization**, users see "Localmem is damaged / can't be
   opened." This is a prerequisite for *every* channel, not a channel itself.
   Cost: Apple Developer Program, **$99/year**, plus a notarization step in CI.

3. **The Mac App Store is ruled out.** Localmem edits *other apps'* config files
   (`~/.claude.json`, `~/.codex/config.toml`, etc.) and shells out to their
   CLIs. The App Store sandbox forbids this. We do not design around MAS.

4. **The GUI is not a `.app` bundle yet.** `localmem-app` is currently a plain
   SwiftPM executable (a bare binary — no Info.plist, icon, or bundle structure).
   Before *any* GUI distribution, it must be wrapped into a signed `.app` bundle
   (via an Xcode wrapper target or a bundling script such as `swift-bundler`).
   This is prerequisite work independent of which channel we choose.

## Channel options — the CLI (`localmem` + `localmem-mcp`)

| Channel | Command | Pros | Cons |
|---|---|---|---|
| **Homebrew formula** | `brew install localmem` | What devs expect; handles PATH, `brew upgrade`, uninstall; trusted | We maintain a tap/formula; distributed bottles still need signing |
| **curl install script** | `curl -fsSL https://localmem.ai/install.sh \| sh` | One-liner; no Homebrew dependency; we fully control it; used by rustup, Deno, Bun, uv, Ollama | "pipe to shell" distrust; we own arch detection (arm64/x86), PATH setup, updates, quarantine handling |
| **Direct tarball** | download + extract to PATH | Zero infrastructure | Fully manual; no update path |

## Channel options — the app (bundles all three binaries)

| Channel | How the user gets it | Pros | Cons |
|---|---|---|---|
| **Notarized DMG** | Website "Download" → drag to /Applications | The macOS-native expectation; polished (background image + arrow) | Manual; updates need Sparkle or a re-download |
| **Notarized ZIP** | Website → unzip → move to /Applications | Simplest artifact to produce; works well with Sparkle | Less "premium" feel than a DMG |
| **Homebrew Cask** | `brew install --cask localmem` | Devs install the GUI with the same tool as the CLI; scriptable | A cask just wraps our DMG/zip — we still produce that artifact |
| **PKG installer** | Website → guided installer | Can place the app *and* symlink the CLI into `/usr/local/bin`, and even run `localmem setup`, in one step | "Installer" feel; needs a separate Installer signing cert; some users distrust pkgs |

## Giving app users the CLI too

Proven pattern (used by VS Code's `code` command and by Ollama): **the app bundles
`localmem` + `localmem-mcp`, and on first run offers to symlink `localmem` into
`/usr/local/bin`.** Result:

- **Download the app** → GUI plus a one-click "install command-line tool."
- **`brew install localmem`** → CLI only, no GUI, for people who never want the app.

The two coexist. The only sharp edge is **version skew** when a user has both the
app's bundled CLI and a separate Homebrew CLI (two different binaries at two
paths). Mitigation: `localmem setup` always registers *its own* sibling
`localmem-mcp` and is idempotent — "whoever ran setup last wins" — and the app's
status view flags a stale registration and offers to repair it.

## Updates

| Component | Update mechanism |
|---|---|
| **App** | **Sparkle** — the standard macOS auto-update framework. The app checks an *appcast* (an XML feed we host, e.g. `localmem.ai/appcast.xml`), shows an in-app "Update available" prompt, downloads, verifies an EdDSA signature, swaps in place, and relaunches. Keeps the app at the same `/Applications` path, so MCP registrations survive updates. |
| **CLI (brew)** | `brew upgrade localmem` |
| **CLI (curl)** | Re-run the install script, or a `localmem upgrade` command |

Sparkle requires us to (a) host the appcast XML on the site and (b) generate an
EdDSA signing key that CI uses to sign each release.

## Recommended shape

Ship both families of channels — DMG-vs-curl is a false choice; they're different
artifacts for different audiences.

- **CLI:** Homebrew formula (primary) **+** curl script (fallback). Both install
  `localmem` + `localmem-mcp`.
- **App:** notarized **DMG** as the website's download button (**+** a ZIP for
  Sparkle), **and** a Homebrew **Cask** (`brew install --cask localmem`). The app
  bundles the CLI and offers the PATH symlink.
- **Updates:** Sparkle for the app; brew / curl for the CLI.
- **Skip the PKG** unless we specifically want the website installer to configure
  the CLI without the app touching `/usr/local/bin` — the app-symlink covers that.

**Reference architectures to copy:** Ollama (app bundles a CLI, installs a
symlink, distributed via DMG + Homebrew cask) and Tailscale (app + CLI across
multiple channels). Both are almost exactly Localmem's shape.

## What the website has to serve

More than a static landing page. It hosts:

- The **download button** (DMG) and the **install command** (`curl … | sh`).
- The **`install.sh`** script itself.
- The **appcast XML** for Sparkle app updates.
- The **release artifacts** (DMG, ZIP) for each version.
- Docs / quick-start.

This implies a small **release pipeline**: CI builds the three binaries
(universal arm64 + x86_64) → assembles the signed `.app` bundle → signs +
notarizes → produces DMG + ZIP → uploads artifacts → updates the appcast +
Homebrew formula/cask.

## Prerequisites & costs

- **Apple Developer Program** — $99/year (Developer ID cert + notarization).
- **Notarization** step wired into CI.
- **`.app` bundling** for `localmem-app` (Xcode wrapper or bundling script).
- **Universal binaries** (arm64 + Intel) or per-arch downloads.
- **EdDSA key** for Sparkle update signing.
- **Homebrew tap** (for formula and cask) if not going into homebrew-core.

## Open decisions (to discuss)

1. **Primary CLI channel** — Homebrew, curl, or both? *(Leaning: both, brew-first.)*
2. **App artifact** — DMG, ZIP, or both? *(Leaning: DMG for the button, ZIP for Sparkle.)*
3. **Homebrew cask for the app** — yes/no? *(Leaning: yes.)*
4. **CLI-from-app** — auto-offer to symlink `localmem` on first run, or leave the CLI to brew/curl only?
5. **Updates** — commit to Sparkle now, or ship re-download-only for v1?
6. **Website scope** — static landing page only, or also host `install.sh` + appcast + release artifacts (i.e. a release pipeline)?
7. **Domain / hosting** — where does the site live, and where do release artifacts live (GitHub Releases vs. own CDN)?

## Out of scope

- Windows / Linux distribution (macOS-only product).
- Mac App Store (sandbox incompatible).
- Enterprise MDM / managed deployment.
