# Building Codex for ipad

## 1. Prerequisites

```bash
xcodebuild -version
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
python3 --version
node --version
npm --version
maturin --version
```

The checked-in project targets iPadOS 18 and Swift 6.

## 2. Prepare local-only dependencies

Run the bootstrap script with an official macOS DMG that you obtained yourself:

```bash
./scripts/bootstrap_public_build.sh /absolute/path/to/ChatGPT.dmg
```

The script:

1. verifies and imports the desktop bundle locally;
2. downloads the pinned BeeWare Python Apple support runtime;
3. rebuilds the locked iOS Python MCP package snapshot locally;
4. builds `CodexCore.xcframework`;
5. regenerates the Xcode project for the imported desktop version.

Generated vendor binaries, extracted desktop resources and build products are ignored by Git.

## 3. Configure signing

Open `CodexPad/CodexPad.xcodeproj`, select the `CodexPad` target and:

- enable **Automatically manage signing**;
- select your Apple Personal Team;
- use a unique Bundle Identifier, for example `dev.yourname.codexforipad`;
- select a connected physical iPad.

Do not commit a Team ID, device UDID, signing certificate, provisioning profile or exported IPA.

## 4. Build and run

Use Xcode Run for the first installation. The project is intended for physical iPad validation; the simulator does not reproduce Keychain, file-provider and hardware-keyboard behavior faithfully.

## 5. Test

Fast source-level checks:

```bash
python3 -m pytest tests
swift test --package-path CodexPad
cargo test --manifest-path CodexCore/Cargo.toml
```

Device UI tests require a connected iPad and your own signing configuration.

## 6. Update desktop resources manually

There is no background auto-updater. To move to a newer desktop build, rerun:

```bash
./scripts/bootstrap_public_build.sh /absolute/path/to/new/ChatGPT.dmg
```

Review generated parity evidence locally before installing a new iPad build.
