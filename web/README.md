# localmem.ai

The marketing site — a single static `index.html` — lives here in the
monorepo and deploys via Vercel (project root directory: `web/`). Pushes to
`main` that touch `web/` deploy automatically; other pushes are skipped.

See [docs/Technical_Design.md](../docs/Technical_Design.md) §12 for the
website & release pipeline.
