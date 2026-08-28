# Changelog

All notable public-source updates are recorded here. Version numbers follow the validated desktop compatibility baseline rather than an App Store release channel.

## 26.814.41957 (build 6744) — 2026-08-28

### Product closure
- Completed the M-series physical iPad Release build, signing, installation and independent cold-launch cycle.
- Completed the full physical-device parity inventory and real-provider response validation.
- Verified official remote model discovery with versioned local fallback behavior.
- Closed the final validation-state leak so test workspaces and validation chats do not remain in a normal user launch.

### Reliability
- Purge renderer entries for newly archived persisted threads.
- Remove exact-name validation projects without touching similarly named user projects.
- Clear selected-project and last-active-thread anchors during explicit UI-test cleanup.
- Harden login, API-key and real-chat UI locators for the released surface.

### Distribution
- Keep credentials, Team IDs, device identifiers, official desktop assets, signed IPA files and local evidence out of the public repository.
- Keep automatic background updates disabled; upgrades remain explicit local operations.
