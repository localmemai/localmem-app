# Security Policy

Localmem stores personal memory locally and mediates AI-agent access to it, so
we take security reports seriously.

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately through GitHub's
[private vulnerability reporting](https://github.com/localmem-ai/localmem-app/security/advisories/new)
("Report a vulnerability" under the repository's **Security** tab). We aim to
acknowledge reports within a few days and will keep you updated on remediation.

## Scope

Localmem is a **single-user, local-first, macOS-only** product. There is no
Localmem-operated server; memory lives in a local SQLite database. Relevant
areas for reports include:

- The MCP server (`localmem-mcp`) and its input handling.
- The CLI (`localmem`) and setup routines that write other clients' config files.
- The vault app (`localmem-app`).
- `LocalmemCore` storage, search, and access-control enforcement.

## Known design boundaries (not vulnerabilities)

These are deliberate design decisions, documented in the
[technical design](docs/Technical_Design.md). Reports about them are welcome as
*design discussion*, but they are known and intentional, not treated as security
defects:

- **Per-memory agent access control is an organizational boundary, not a security
  wall.** Agent identity is a self-declared `actor_id` supplied over MCP; a
  misbehaving agent can claim another agent's name. Hardened per-client identity
  is possible future work.
- **The full-text search index (FTS5) holds plaintext.** Search-index
  confidentiality under at-rest encryption is an open design question.
- **The CLI and app are admin surfaces** that intentionally bypass per-memory
  access filtering.

## Supported versions

Localmem is pre-1.0 and under active development. Security fixes are made against
the `main` branch; there is no back-porting to older tags yet.
