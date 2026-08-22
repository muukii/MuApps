# CLAUDE.md — Tinycurve

Guidance for working in `Apps/Journal/`. The repo-root `CLAUDE.md` and
`coding-guide.md` still apply; this file adds Journal-specific context.

## What this app is

A journaling app (iPhone + iPad + native macOS) where each captured thing becomes one **Card**.
iCloud sync and vault collaboration are hard requirements. The app shell now
writes and reads user-facing entries through the `JournalVault` architecture:
per-vault SwiftData stores with CloudKit mirroring disabled and explicit sync
owned by the CloudKit sync boundary. App UI should work through the selected
`VaultInstance`; CloudKit transport objects stay behind that boundary. The
legacy `JournalModel` module has been removed from the app project; product
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

- `Sources/Journal/` — app shell: `TinycurveApp`, creation/list/settings features,
  app-local components, notification UI, and app resources such as `Icon.icon`.
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
  shows the authored latest item. Home Screen widgets use modality labels for
  photo/video/Live Photo, render Doodle/Bauhaus authored JSON through SwiftUI
  renderers, and keep tight accessory families on labels/symbols.
- `Sources/JournalShareExtension/` — **Share extension** (`.appExtension`):
  `ShareViewController` only. It is the declared `NSExtensionPrincipalClass` and
  must stay in the `.appex`.
- `Sources/JournalShareUI/` — the Share extension's review sheet, model, payload,
  and import loader, as a **dynamic** framework. **Keep this out of the `.appex`,
  and keep it dynamic.** Xcode Previews does not support share-service extension
  targets, so UI living in the extension cannot be previewed at all, and an
  `.appex` cannot host a unit test target. The dynamic part is specifically about
  this target's dependency graph, not a general rule — static frameworks preview
  fine here (`MuHaptics`, `CaptureAudio`, `CaptureSuggestions` all do), because
  they depend on nothing local. This one depends on sibling frameworks, and
  while it was static Previews JIT-linked `JournalShareUI` alone and loaded no
  dependency product, leaving `JournalVault` / `JournalIntents` symbols unbound.
  As a dynamic framework it is a real Mach-O
  whose load commands name its dependencies, so dyld resolves the closure.
  Rule of thumb for this project: **a framework with local framework dependencies
  that needs Previews must be dynamic.** Built extension-API-only and embedded in
  the app's `Frameworks/`; the `.appex` reaches it through
  `@executable_path/../../Frameworks`.
- `Sources/Capture*/` — capture frameworks (one isolated static framework each):
  `CaptureText`, `CapturePhoto`, `CaptureDoodle`, `CaptureBauhaus`,
  `CaptureAudio`, `CaptureSuggestions`.
- `Sources/MuColor/`, `Sources/MuHaptics/` — support frameworks for themes/palette
  and Core Haptics labs.
- `Tests/JournalUITests/` — UI tests.
- `Project.swift` — Tuist manifest (targets, entitlements, Info.plist).

## Conventions specific to Journal

- **Capture components stay persistence-agnostic.** Each emits a plain `Sendable`
  value type through a `@MainActor @Sendable` callback (`CapturedText`,
  `CapturedPhoto`, `DoodleDrawing`, `BauhausGridDocument`, `AudioRecording`,
  `CapturedSuggestion`) and must know nothing about `Card`, SwiftData, or
  iCloud. Don't couple them to the app shell. Original attachment resources are
  the only persisted media source; bounded display decoding belongs at the
  presentation boundary and does not create a synced derivative.
- **Legacy migration is CloudKit-owned, not local SQLite-owned.** The app shell
  must not recreate the old local SwiftData model layer as a startup migration
  source. A product migration must query legacy CloudKit records / CKAssets and
  write the target vault zone, then let `VaultSyncEngine` import those records
  into the selected local vault store. Do not inject a legacy container into
  SwiftUI, and do not reintroduce `MediaSyncEngine`, `SyncStatusMonitor`, or
  legacy saved-entry share/edit UI. New product code should use `JournalVault`.
- **The widget is a vault reader.** `JournalWidget` links `JournalVault`, lists
  vault choices from `VaultCatalogStore`, and opens the configured
  `VaultContentStore` only long enough to build a `Sendable` `NoteSnapshot`.
  Do not reintroduce legacy model reads for product widget behavior.
- **Theming goes through `MuColor`.** Use the palette/app shape styles
  (`.appPrimaryContainer`, etc.) and `PrimaryContainer`/`SecondaryContainer`
  rather than hard-coded colors. Five seed colors only — no new hues.
- **`CaptureSuggestions` is device-only and fragile to link.** `JournalingSuggestions`
  is absent from the Simulator SDK and the Mac Designed-for-iPad runtime; Apple
  does not ship the framework for native macOS.
  Keep all framework-touching code behind `#if canImport(JournalingSuggestions)`,
  keep `@_weakLinked import JournalingSuggestions` in every file that imports it
  (a plain `import` re-strengthens the autolink and crashes on Mac at launch),
  compile the fallback for native macOS, and keep the
  `ProcessInfo.isiOSAppOnMac` runtime guard + `AnyView` erasure for Designed-for-iPad.

## Build & run

```bash
tuist install && tuist generate
xcodebuild -workspace MuApps.xcworkspace -scheme Tinycurve \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Use the normal **Tinycurve** scheme for CloudKit Development. Use the shared
**Tinycurve Production** scheme to keep `DEBUG` behavior and debugger attachment
while connecting to CloudKit Production through the `DebugProduction`
configuration. Production CloudKit must be exercised on a physical iOS device or
the signed native macOS app; the iOS Simulator only accesses Development. The
build setting also routes Simulator-local stores to Development for consistency.
Production scheme defines no test targets and uses the shipping bundle ID, so it
can replace the normal local install and mutate or delete real production records.

Use **iPhone 17 / OS 27.0** (no iPhone 16 simulator on this machine). Capture
components have their own schemes for isolated runs. `CapturePhoto` is implemented
directly on AVFoundation.
