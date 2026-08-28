# Roadmap

Codex for ipad uses the latest released desktop Codex experience as its compatibility reference. The initial physical-device product closure is complete; the roadmap now focuses on maintaining parity as desktop behavior, model availability and iPadOS evolve.

## Release baseline — complete

- [x] SwiftUI iPad application shell and desktop-compatible WKWebView surface
- [x] ChatGPT and API-key authentication with Keychain persistence
- [x] Official account model catalog with versioned fallback
- [x] Streaming chat, cancellation, resume and persisted conversation state
- [x] Projects, Files/iCloud Drive access, search, patching and diff review
- [x] Git status, Review, Side Chat and Terminal interaction routes
- [x] MCP HTTP/OAuth and embedded Node/Python runtime integration
- [x] Settings, usage, plugins, skills and supporting AppHost service domains
- [x] M-series physical iPad Release build, signing, installation and cold launch
- [x] Full physical-device parity suite, real-provider response and clean-state closure
- [x] Background automatic updater removed; upgrades are explicit and manual

## Maintenance track

### Desktop parity
- Track visible desktop UI, protocol and interaction changes per official release.
- Keep the remote model catalog authoritative and update the fallback catalog only as a resilience measure.
- Extend physical-keyboard layout coverage when new shortcuts appear.

### iCloud project continuity
- Improve conflict-copy visibility and last-sync diagnostics without replacing Apple Files/iCloud Drive semantics.
- Add clearer project handoff guidance for large repositories and offline transitions.

### Provider and MCP breadth
- Expand the verified matrix for custom Provider adapters, tool-event variations and rate-limit recovery.
- Add more embedded-runtime compatibility fixtures for commonly used MCP servers.

### Release engineering
- Keep public-source safety checks mandatory.
- Maintain reproducible local bootstrap, unsigned source builds and Personal Team installation guidance.
- Record each validated desktop baseline in `CHANGELOG.md` and `docs/RELEASE_ACCEPTANCE.md`.

## Non-goals

- Distributing official installers, extracted desktop resources or signed IPA files.
- Bypassing Apple signing or provisioning requirements.
- Running arbitrary macOS executables directly on iPadOS.
- Replacing iCloud Drive with a private cloud synchronization service.
