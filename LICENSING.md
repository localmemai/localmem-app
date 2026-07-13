# Licensing

Localmem is **open-core**. Everything that touches your memories — the storage
engine, the CLI, and the MCP server your agents talk to — is fully open source.
The macOS app is **source-available**: you can read every line, build it
yourself, and contribute, but you can't ship a competing product with it.

| Component | Path | License |
|---|---|---|
| Core engine (storage, search, permissions, audit) | `Sources/LocalmemCore` | [Apache 2.0](LICENSE) |
| CLI (`localmem`) | `Sources/localmem` | [Apache 2.0](LICENSE) |
| MCP server (`localmem-mcp`) | `Sources/localmem-mcp` | [Apache 2.0](LICENSE) |
| macOS app (`localmem-app`) | `Sources/localmem-app` | [FSL-1.1-ALv2](Sources/localmem-app/LICENSE.md) |
| Tests, docs, packaging, website | everything else | [Apache 2.0](LICENSE) |

## Why this split

Localmem's promise is that your memories never leave your Mac. That promise is
only worth something if you can verify it — so the app's source stays public
and auditable, and the components agents actually talk to are fully open
source under Apache 2.0.

The app is licensed under the [Functional Source License][fsl]
(FSL-1.1-ALv2): free to use, read, modify, and contribute to, with one
restriction — no competing use. **Each release automatically converts to
Apache 2.0 two years after it ships**, so even the app becomes fully open
source on a rolling basis.

## Contributing

Contributions are welcome everywhere, including the app. Because the app is
commercially licensed, we ask contributors to sign a lightweight
[Contributor License Agreement](CLA.md) (automated on your first pull
request) so we can keep licensing the combined work. See
[CONTRIBUTING.md](CONTRIBUTING.md).

[fsl]: https://fsl.software
