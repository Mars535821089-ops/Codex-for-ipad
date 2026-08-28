# Release Acceptance

## Validated baseline

| Item | Result |
|---|---|
| Desktop compatibility identity | `26.814.41957` / build `6744` |
| Target | arm64 iPhoneOS Release |
| Device class | Physical M-series iPad |
| Signing/install/launch | Passed with Apple Development signing |
| Full visible parity inventory | Passed |
| Real provider response | Passed with the expected streamed response |
| Clean post-validation launch | Passed |
| Automatic updater | Disabled |

## Acceptance layers

A release is accepted only when all four layers agree:

1. **Source and contract tests** — Swift domain tests, Rust tests, Python contracts and shell syntax.
2. **Release artifact** — arm64 iPhoneOS Release build with a valid application identity.
3. **Physical-device execution** — install, launch, foreground process and cold-launch behavior on a connected M-series iPad.
4. **User workflow evidence** — login, official model catalog, projects, chat, files, Git/Review, Side Chat, Terminal, MCP and settings paths.

## Privacy of evidence

Raw device logs, screenshots, result bundles, account state and signed packages remain local. The public repository records the acceptance result and test implementation, not private device artifacts.

## Future baseline updates

For each newer desktop compatibility version:

1. import the user-supplied official package locally;
2. regenerate compatible resources and catalogs;
3. run source and contract checks;
4. build and install a new Release on physical iPad;
5. repeat full parity, real-provider and clean-state acceptance;
6. update this file and `CHANGELOG.md` only after all layers pass.
