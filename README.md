# Anyone Protocol × Pi × zkAPI — Private AI Agent Demo

A terminal demo using the **Pi coding agent**, **paid zkAPI Mainnet inference**, and **Anyone-routed HTTPS research** with bounded background cover traffic.

The recording shows the agent searching and reading web sources, handling failed requests, and presenting its findings. The coloured output is a live event renderer, not a pre-recorded transcript.

## Components

- **Pi** (`@earendil-works/pi-coding-agent`) invokes the web research extension.
- **zkAPI Mainnet** supplies paid AI inference (`anthropic/claude-haiku-5.5`). Our custom client adds per-request `X-Anyone-Isolation` enforcement when configured with a `tor://` transport.
- **Anyone** provides a local SOCKS listener at `127.0.0.1:9150` for HTTPS research and the configured zkAPI relay.
- **Cover traffic** produces bounded independent SOCKS-authenticated HTTPS requests while the agent runs.

**Verification scope:** Paid zkAPI inference, Anyone-routed research requests, isolation unit tests and cover traffic have been tested. Independent packet-level verification of each live inference request's path has not been completed. Do not present that as verified in published descriptions.

## Repository layout

```text
tools/record-anyone-zkapi-demo.sh        Final colour terminal recorder
tools/pi/anyone-research-demo.ts         Research tool with retry behaviour
tools/pi/anyone-research.ts              Base Anyone web research extension
tools/pi/anyone-fetch.ts                 Anyone exit-IP / HTTP verification tool
tools/pi/package.json                   Pi dependency manifest
src/anyone-cover-demo/main.go           Standalone copy of cover entrypoint
patches/zkapi-mainnet-isolation.patch    Changes against pinned upstream zkAPI
zkapi-additions/                        Additional client and cover Go code
scripts/build-custom-client.sh          Rebuild customized binaries
examples/models.example.json            Non-secret Pi model configuration
```

## Requirements

- macOS ARM64 for the tested local runtime; other OS/architectures require their own builds.
- Git, Go (the tested Mac build used Go 1.26.10), Node.js and npm, Python 3, curl and `nc`.
- A separately installed and running Anyone SOCKS client on `127.0.0.1:9150`.
- A locally configured, **funded** zkAPI Mainnet wallet/profile. The repository deliberately provides no wallet or private keys.
- Permission to access the public URLs used by the research and cover tools.

## Install the dependencies

```bash
npm ci --prefix tools/pi
./scripts/build-custom-client.sh
```

The build script checks out pinned upstream zkAPI source, applies the patch, copies the added Go sources, runs the Go tests, and builds the custom client and cover runner. Build outputs are local-only and ignored by Git.

Create `profiles/pi/models.json` from `examples/models.example.json` and keep it local. Populate its environment variables in the shell when starting Pi, rather than putting real secrets in files.

Configure the local zkAPI client through `tools/zkapi-clientd-isolated-test --config-dir profiles/mainnet config`; do not create or import a funded wallet using shared terminal logs or published screenshots. You will need an existing funded profile to run the demo. Start the configured zkAPI service with:

```bash
./tools/zkapi-clientd-isolated-test --config-dir profiles/mainnet serve
```

Keep this service running. In a separate shell, with Anyone running:

```bash
./tools/record-anyone-zkapi-demo.sh
```

**Costs:** The demo uses real paid inference and may incur ETH charges against the configured private zkAPI balance. The code is not designed as a no-cost offline demo.

## Source reproducibility

The customized zkAPI client is rebuilt against upstream repository `ethereum/zkapi` commit:

`32b97d19c6ceb2c2c1b5ef99a9ecac2266467255`

The cover runner source was originally developed against a separate zkAPI source revision (`106168594f01363d6558682d10a7a7b0f50f6fcc`) and has been tested together with the pinned Mainnet client.

The `patches` and `zkapi-additions` paths are project modifications and should not be confused with unmodified upstream zkAPI releases. Respect the included upstream license notices.

## Security and privacy

- Never commit `profiles/`, `.private-backups/`, wallet notes, API keys, management tokens or local session transcripts.
- The temporary `X-Anyone-Isolation` value is a per-run random value. It is a routing identity, **not** proof of anonymity.
- Pi connects to its local API over loopback; the remote zkAPI and Anyone transports have distinct trust and privacy boundaries.
- The cover traffic is bounded and **does not prove** that real requests cannot be correlated.
- Inspect every staged file before creating a public repository. Publish **private** first.

## Tests

`./scripts/build-custom-client.sh` runs the cover, relay and server package tests as well as the cover command build check. The research recorder has been exercised live on Mainnet, but live service availability and web results can vary.
