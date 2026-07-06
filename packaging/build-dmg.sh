#!/usr/bin/env bash
#
# build-dmg.sh — assemble, sign, notarize, and package Localmem.app into a DMG.
#
# Produces a drag-to-Applications DMG containing Localmem.app, which bundles all
# three co-located binaries:
#
#   Localmem.app/Contents/MacOS/
#     ├── localmem-app            (the GUI, CFBundleExecutable)
#     ├── localmem                (the CLI)
#     ├── localmem-mcp            (the MCP server clients talk to)
#     └── Localmem_LocalmemCore.bundle, GRDB_GRDB.bundle  (SwiftPM resources)
#
# Why they must stay together: `localmem setup` registers the ABSOLUTE path of
# localmem-mcp into each AI client's config. Inside the bundle that path is
# /Applications/Localmem.app/Contents/MacOS/localmem-mcp — versionless and stable,
# so it keeps working across in-place updates. User data (memories in
# ~/Library/Application Support/Localmem, instructions in ~/.localmem) lives
# OUTSIDE the bundle and is never touched by install or update.
#
# Usage:
#   VERSION=0.1.0 packaging/build-dmg.sh
#
# Signing + notarization are enabled by setting these (leave unset for an
# unsigned local build — fine for testing, NOT distributable, Gatekeeper will
# reject it):
#   SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE  name of a `xcrun notarytool store-credentials` keychain profile
#
set -euo pipefail

# ---- config (override via env) ---------------------------------------------
VERSION="${VERSION:-0.0.0}"
BUILD_VERSION="${BUILD_VERSION:-$VERSION}"
BUNDLE_ID="${BUNDLE_ID:-ai.localmem.app}"
MIN_MACOS="${MIN_MACOS:-26.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
# Space-separated arch list; default universal. Override e.g. ARCHS="arm64" for
# a fast local build.
read -ra _ARCH_LIST <<< "${ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for a in "${_ARCH_LIST[@]}"; do ARCH_FLAGS+=(--arch "$a"); done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$REPO_ROOT/packaging"
OUT_DIR="$REPO_ROOT/dist"
APP="$OUT_DIR/Localmem.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
DMG="$OUT_DIR/Localmem-$VERSION.dmg"

BINARIES=(localmem-app localmem localmem-mcp)
# SwiftPM resource bundles (*.bundle) are discovered from the build products at
# assembly time, so a newly added one (e.g. the app's AgentIcons) travels
# automatically instead of needing this list kept in sync.
RESOURCE_BUNDLES=()

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

# ---- 1. build universal release binaries -----------------------------------
log "Building universal (arm64 + x86_64) release binaries…"
swift build -c release "${ARCH_FLAGS[@]}" --package-path "$REPO_ROOT" >/dev/null
BIN_PATH="$(swift build -c release "${ARCH_FLAGS[@]}" --package-path "$REPO_ROOT" --show-bin-path)"
log "Built products in $BIN_PATH"

# ---- 2. assemble the .app bundle -------------------------------------------
log "Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

for bin in "${BINARIES[@]}"; do
	cp "$BIN_PATH/$bin" "$MACOS_DIR/$bin"
done
# Copy every SwiftPM resource bundle next to the binaries so Bundle.module
# resolves (LocalmemCore's AGENTS.md, GRDB, the app's AgentIcons, …).
while IFS= read -r bundle; do
	[ -n "$bundle" ] || continue
	name="$(basename "$bundle")"
	cp -R "$bundle" "$MACOS_DIR/$name"
	RESOURCE_BUNDLES+=("$name")
done < <(find "$BIN_PATH" -maxdepth 1 -name '*.bundle')

# Info.plist with the concrete version/id substituted in.
sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
	-e "s/__SHORT_VERSION__/$VERSION/" \
	-e "s/__BUILD_VERSION__/$BUILD_VERSION/" \
	-e "s/__MIN_MACOS__/$MIN_MACOS/" \
	"$PKG_DIR/Info.plist" > "$APP/Contents/Info.plist"

if [ -f "$PKG_DIR/AppIcon.icns" ]; then
	cp "$PKG_DIR/AppIcon.icns" "$RES_DIR/AppIcon.icns"
else
	log "WARNING: packaging/AppIcon.icns not found — app will use the generic icon."
fi

# ---- 3. code-sign ----------------------------------------------------------
if [ -n "$SIGN_IDENTITY" ]; then
	log "Code-signing with: $SIGN_IDENTITY"
	# Sign inside-out: nested bundles and helper binaries first, app last.
	for b in "${RESOURCE_BUNDLES[@]}"; do
		[ -e "$MACOS_DIR/$b" ] && codesign --force --timestamp --options runtime \
			--sign "$SIGN_IDENTITY" "$MACOS_DIR/$b"
	done
	# Sign the two helper executables before the main one.
	for bin in localmem localmem-mcp; do
		codesign --force --timestamp --options runtime \
			--sign "$SIGN_IDENTITY" "$MACOS_DIR/$bin"
	done
	codesign --force --timestamp --options runtime \
		--sign "$SIGN_IDENTITY" "$MACOS_DIR/localmem-app"
	# Seal the whole bundle.
	codesign --force --timestamp --options runtime \
		--sign "$SIGN_IDENTITY" "$APP"
	codesign --verify --deep --strict --verbose=2 "$APP"
else
	# No Developer ID: ad-hoc sign so the bundle is internally valid and launches
	# on Apple Silicon after the user clears quarantine. This is NOT notarized and
	# still trips Gatekeeper on download — see the "unsigned pre-release" note.
	log "WARNING: SIGN_IDENTITY not set — ad-hoc signing an UNSIGNED (un-notarized) bundle."
	log "         Downloaders must bypass Gatekeeper manually. Not for a public download button."
	for b in "${RESOURCE_BUNDLES[@]}"; do
		[ -e "$MACOS_DIR/$b" ] && codesign --force --sign - "$MACOS_DIR/$b"
	done
	for bin in localmem localmem-mcp localmem-app; do
		codesign --force --sign - "$MACOS_DIR/$bin"
	done
	codesign --force --sign - "$APP"
fi

# ---- 4. build the DMG ------------------------------------------------------
log "Building ${DMG}…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Localmem.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Localmem" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

# ---- 5. notarize + staple --------------------------------------------------
if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_PROFILE" ]; then
	log "Submitting DMG to Apple notary service (profile: $NOTARY_PROFILE)…"
	xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
	log "Stapling notarization ticket…"
	xcrun stapler staple "$DMG"
	xcrun stapler validate "$DMG"
elif [ -n "$SIGN_IDENTITY" ]; then
	log "WARNING: NOTARY_PROFILE not set — DMG is signed but NOT notarized (Gatekeeper will still warn)."
fi

log "Done: $DMG"
