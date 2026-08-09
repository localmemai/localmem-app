# Release notes

One file per release, named for the version: `2.0.0.md`, `2.0.1.md`.

The release workflow refuses to build a tag whose file is missing, and composes
the published body as:

1. this file's contents
2. GitHub's generated pull-request list
3. checksums

That order exists because the app's update dialog renders the body verbatim in a
short scroll area — the first few lines are all most users read, so hand-written
notes lead and reference material sits below.

See [`RELEASING.md`](../../RELEASING.md), including when a release needs a
`## Security` heading.
