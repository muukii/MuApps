# CLAUDE.md — Journal

Guidance for working in `Apps/Journal/`. The repo-root `CLAUDE.md` and
`coding-guide.md` still apply; this file adds Journal-specific context.

## What this app is

A journaling app (iPhone + iPad) where each captured thing becomes one **Card**.
iCloud sync and vault collaboration are hard requirements. The app shell now
writes and reads user-facing entries through the `JournalVault` architecture:
per-vault SwiftData stores with CloudKit mirroring disabled and explicit sync
owned by the CloudKit sync boundary. App UI should work through the selected
`VaultInstance`; CloudKit transport objects stay behind that boundary. The
legacy `JournalModel` store is no longer opened by the app shell; product
migration should read legacy CloudKit records and write the target vault zone.

The app is **pre-product**: the real journaling UI is still being shaped. Today
the root is vault-first: after onboarding, `VaultSelectionView` opens a selected
`VaultInstance`, then `CreationView` composes inside that vault. Settings are
reachable from the vault picker and composer, and the vault-backed entries list
is reachable from the composer toolbar. Read
`docs/SPECIFICATION.md` for the full, current state — keep it updated when
behavior changes (see its Documentation Policy; this is in addition to the
repo-root `docs/SPECIFICATION.md`, which is about distribution, not product
behavior).

## Layout

- `Sources/Journal/` — app shell: `JournalApp`, creation/list/settings features,
  app-local components, notification UI, and app resources such as `Icon.icon`.
- `Sources/JournalModel/` — **shared data layer** (dynamic framework): `Card`, `Tag`,
  `Attachment`, `CardRelationship`, `Coordinate`, and `JournalStore` (the schema
  + the one shared-container factory). Built extension-API-only for narrow
  local tooling compatibility. `JournalStore`'s public persistence/media entry
  points are intentionally deprecated as migration warnings; do not add new
  callers except for explicit legacy migration tooling.
- `Sources/JournalVault/` — **target-architecture data layer** (dynamic framework,
  extension-API-only): per-vault SwiftData stores with CloudKit mirroring
  *disabled* plus the explicit sync layer (`VaultCatalogStore`,
  `VaultContentStore`, `VaultSyncEngine` / CKSyncEngine-backed
  `CloudKitVaultSyncEngine`). See `docs/VAULT_SYNC_DESIGN.md` (実装状況 section)
  — the app shell starts the logging runtime, bootstraps vaults, then uses the
  user's selected `VaultInstance` for save/list UI.
  Unit tests in `Tests/JournalVaultTests/` (run via the `JournalVault` scheme's
  test action).
- `Sources/JournalWidget/` — **WidgetKit extension** (`.appExtension`): `JournalWidgetBundle`
  (`@main`) + `LatestNoteWidget`, which lets each widget instance choose a vault
  through WidgetKit configuration, reads the selected `JournalVault` store, and
  shows the authored latest item, including doodle thumbnails when available.
- `Sources/Capture*/` — capture frameworks (one isolated static framework each):
  `CaptureText`, `CapturePhoto`, `CaptureDoodle`, `CaptureAudio`,
  `CaptureSuggestions`.
- `Sources/MuColor/`, `Sources/MuHaptics/` — support frameworks for themes/palette
  and Core Haptics labs.
- `Tests/JournalUITests/` — UI tests.
- `Project.swift` — Tuist manifest (targets, entitlements, Info.plist).

## Conventions specific to Journal

- **Capture components stay persistence-agnostic.** Each emits a plain `Sendable`
  value type through a `@MainActor @Sendable` callback (`CapturedText`,
  `CapturedPhoto`, `DoodleDrawing`, `BauhausGridDocument`, `AudioRecording`,
  `CapturedSuggestion`) and must know nothing about `Card`, SwiftData, or
  iCloud. Don't couple them to the app shell.
- **Legacy SwiftData models obey CloudKit-mirroring constraints.** Every stored
  property optional-or-defaulted, no `.unique`, every relationship optional,
  inverse declared on one side only. This applies to `JournalModel`, which now
  exists for legacy migration and local tooling; do not add new product writes
  to it.
- **Legacy migration is CloudKit-owned, not local SQLite-owned.** The app shell
  should not open `JournalStore` as a startup migration source. A product
  migration must query legacy CloudKit records / CKAssets and write the target
  vault zone, then let `VaultSyncEngine` import those records into the selected
  local vault store. Do not inject the legacy container into SwiftUI, and do not
  reintroduce `MediaSyncEngine`, `SyncStatusMonitor`, or legacy saved-entry
  share/edit UI. New product code should use `JournalVault`.
- **The widget is a vault reader.** `JournalWidget` links `JournalVault`, lists
  vault choices from `VaultCatalogStore`, and opens the configured
  `VaultContentStore` only long enough to build a `Sendable` `NoteSnapshot`.
  Do not reintroduce `JournalModel` reads for product widget behavior.
- **Theming goes through `MuColor`.** Use the palette/app shape styles
  (`.appPrimaryContainer`, etc.) and `PrimaryContainer`/`SecondaryContainer`
  rather than hard-coded colors. Five seed colors only — no new hues.
- **`CaptureSuggestions` is device-only and fragile to link.** `JournalingSuggestions`
  is absent from the Simulator SDK *and* the Mac (Designed for iPad) runtime.
  Keep all framework-touching code behind `#if canImport(JournalingSuggestions)`,
  keep `@_weakLinked import JournalingSuggestions` in every file that imports it
  (a plain `import` re-strengthens the autolink and crashes on Mac at launch),
  and keep the `ProcessInfo.isiOSAppOnMac` runtime guard + `AnyView` erasure.

## Build & run

```bash
tuist install && tuist generate
xcodebuild -workspace MuApps.xcworkspace -scheme Journal \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Use **iPhone 17 / OS 27.0** (no iPhone 16 simulator on this machine). Capture
components have their own schemes for isolated runs. `CapturePhoto` is implemented
directly on AVFoundation.
