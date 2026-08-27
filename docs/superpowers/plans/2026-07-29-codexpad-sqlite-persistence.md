# CodexPad SQLite Persistence Implementation Plan

> Phase 07 keeps SQLite ownership inside Rust Core. SwiftUI continues to consume only ordered `DomainEvent` values.

**Goal:** Persist the complete session event stream in an app-container SQLite database, restore it deterministically after relaunch, migrate schemas with pre-migration snapshots, and delete snapshots only after explicit validation confirmation.

**Architecture:** `CodexCore` gains a storage module backed by SQLite. `storage.open` opens or creates a database, snapshots an existing older schema before migration, validates and replays stored events into a candidate session index, then atomically activates storage and queues recovery events. Every session command runs against a cloned candidate index; its event batch is committed to SQLite before the in-memory state and public queue advance. `storage.confirm` records validation and removes only the owned migration snapshot. `storage.restore` closes the database, atomically restores a named owned snapshot, and reopens/replays it. Swift encodes these commands and the application opens storage at launch using an Application Support path.

**Constraints:** No credentials in SQLite. No UI reads SQLite. No deletion outside the owned snapshot directory. Existing `ping` and session JSON remain byte-identical. M-series iPad device builds must retain native arm64 output.

---

## Task 1: SQLite schema and atomic Core storage

**Files:** modify `CodexCore/Cargo.toml`, `CodexCore/src/lib.rs`, `CodexCore/src/session.rs`; create `CodexCore/src/storage.rs`.

1. Add failing Rust tests for first open, persistence/reopen replay, rejected-command atomicity, corrupt event rejection, and old-schema snapshot/migration.
2. Add SQLite dependency and schema v1: `metadata`, `events`, `upgrade_snapshots`.
3. Make `SessionIndex` cloneable and rebuildable from validated event bytes.
4. Implement `storage.open`, transactional event append, explicit `storage.confirm`, and owned snapshot restore.
5. Run Rust tests, Clippy, and existing ABI smokes; commit.

## Task 2: Swift storage envelopes and store recovery

**Files:** modify Core envelope/client/store and Swift tests.

1. Add failing fixed-path encoding tests and fake-transport recovery tests.
2. Add `CodexCoreCommand.openStorage`, `confirmStorage`, and `restoreStorage` with deterministic wire JSON.
3. Add store APIs that drain replayed domain events before enabling interaction.
4. Preserve transport and reducer diagnostics separately; commit after all Swift tests pass.

## Task 3: App-container launch integration

**Files:** modify `CodexPadApp.swift`, presentation status surfaces, generator contract tests.

1. Resolve Application Support/CodexPad paths without hard-coded user paths.
2. Create database and snapshot directory names, call storage open before presenting normal interaction, and surface recovery/migration failures.
3. Add explicit validation confirmation only after storage replay and Core health check succeed.
4. Compile generic Simulator and generic arm64 iPad device variants; commit.

## Task 4: Exported-ABI persistence smoke and failure fixtures

**Files:** create persistence ABI example, exact fixtures, Python contract tests.

1. Run create/write/destroy/reopen/replay solely through the public C ABI.
2. Verify exact six replayed events, continued sequence 7+, database integrity, and no snapshot deletion before confirmation.
3. Verify an injected legacy schema produces an owned snapshot and confirmation removes only that snapshot.
4. Commit deterministic evidence.

## Task 5: Phase 07 verification and merge

**Files:** create `reports/phase-07-sqlite-persistence.md`.

1. Record schema, migration, snapshot hashes, replay evidence, test counts, app/Core architectures, and current parity blockers.
2. Run clean Rust/Python/Swift/XCFramework/generic Simulator/generic device verification.
3. Fast-forward merge to main, reverify from main, retain main artifacts, and remove only the owned worktree/branch.

## Evidence boundary

This phase proves durable local session recovery and safe schema transition. It does not claim provider generation, tools, signing, installation, physical-device execution, or parity closure.
