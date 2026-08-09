# Releasing Localmem

Pushing a `v*` tag is the whole release. [`.github/workflows/release.yml`](.github/workflows/release.yml)
builds the universal binaries, assembles and signs `Localmem.app`, signs the DMG
container, notarizes and staples it, verifies the Gatekeeper verdict, and
publishes a GitHub Release with the versioned DMG, the stable `Localmem.dmg`
alias the website links to, and checksums.

Two things the automation **cannot** check for you. Both are below.

## Before tagging

1. **Bump `LocalmemVersion.current`** in
   [`Sources/LocalmemCore/LocalmemVersion.swift`](Sources/LocalmemCore/LocalmemVersion.swift)
   to match the tag you are about to push.

   This one *is* enforced — the workflow fails fast when the constant doesn't
   equal the tag. It exists because the MCP and CLI version silently sat at
   `0.1.0` across three releases.

2. **Write the release notes**, and if the release fixes a security issue, give
   them a `## Security` heading.

   **Not enforced, and it has to be right.** Nothing in the GitHub API marks a
   release as security-relevant, so the app's update check reads that heading
   out of the release body — across *every* release newer than the one a user is
   running, so a fix in 1.1.0 still reaches someone jumping 1.0.1 → 1.3.0. Omit
   the heading and those users are told an ordinary update is available, with no
   indication it matters. There is no way to correct this after the fact for
   anyone who already saw the dialog.

   The check matches `## Security` or a literal `[security]` marker,
   case-insensitively. It deliberately does *not* match a bare "security fix"
   substring, so notes may say "contains no security fixes" without tripping it.

3. **Sanity-check the release notes render**, since the update dialog shows the
   raw body text.

4. **Regenerate the screenshots if the UI moved.**

   ```bash
   ./scripts/screenshots.sh      # run from Terminal, not from an IDE
   ```

   Seeds a fictional vault and captures each screen against it, so nothing
   personal is ever photographed — the script refuses to run if pointed at the
   real vault, since Settings displays the vault path and the memories speak for
   themselves. Requires Screen Recording permission; macOS prompts on the first
   attempt, but only when the request comes from a terminal with a UI — from a
   background helper it fails silently.

   **The agent-usage panel on the site is markup, not screenshots**, and should
   stay that way. A real captured session publishes whatever it happened to
   contain — working directory, account details in the client's own chrome,
   scrollback — and every refresh reopens that risk.

   Screenshots rot quietly, and stale ones are worse than none: `vault.png` once
   sat beside a caption promising folders while showing a build that had none,
   and `access.png` advertised a section that had been removed entirely. Check
   each caption in `web/index.html` still matches its image.

## Tag and push

```bash
git tag v1.0.2
git push origin v1.0.2
```

## After the release lands

**Exercise the in-app update path once.** Its full sequence — check, download,
Gatekeeper verify, mount, quit, drag — can only be run against a real published
release, so a green CI run is not evidence it works. From a copy of the
*previous* version:

1. **Check for Updates** offers the new version, and offers the *highest* one if
   several are newer.
2. If the notes carry `## Security`, the dialog says so.
3. **Download Update** verifies and mounts; the volume that opens is the new
   version, not a stale `/Volumes/Localmem` from an earlier attempt.
4. **Quit and Install** quits the app and leaves the volume window up.
5. Dragging over `/Applications/Localmem.app` and reopening keeps every MCP
   client registration working — the registered path is inside the bundle and
   does not change across updates.

A deliberate way to test the rejection path: point the checker at any unsigned
DMG. `spctl` exits non-zero, and the app must delete the image and refuse to
proceed rather than mounting it.

## Distribution notes

- **Updates are user-driven.** There is no in-place installer and no Sparkle —
  see [§12 of the technical design](docs/Technical_Design.md) for why. The user
  drags the new app over the old one.
- **User data is never inside the bundle.** Memories live in
  `~/Library/Application Support/Localmem/`, instruction files in `~/.localmem/`,
  and client configs in each client's own file. An update only replaces binaries.
- **Unsigned local builds** are fine for testing (`packaging/build-dmg.sh` with
  no `SIGN_IDENTITY`) but are not distributable — Gatekeeper rejects them, and
  the app's own update verification will reject them too, by design.
