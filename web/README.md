# localmem-web

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![CI](https://github.com/localmemai/localmem-web/actions/workflows/ci.yml/badge.svg)](https://github.com/localmemai/localmem-web/actions/workflows/ci.yml)

Marketing site for [Localmem](https://localmem.ai) — local-first, persistent memory for AI agents.

A single static page (`index.html`), no build step. Deployed on Vercel.

## Develop

Open `index.html` in a browser, or serve it:

```bash
python3 -m http.server 8080   # then visit http://localhost:8080
```

## Deploy

Auto-deploys to Vercel on every push to `main`. Because `index.html` is at the
repo root, no build command or root-directory override is needed — Vercel serves
it as a static site. `vercel.json` sets clean URLs and basic security headers.

## Notes

- The **Download** button and the `curl … | sh` install command are placeholders
  until release artifacts and `install.sh` exist.
- Source of truth for the product lives in the main app repo,
  [`localmemai/localmem-app`](https://github.com/localmemai/localmem-app).
