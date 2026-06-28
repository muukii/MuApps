# CLAUDE.md — Journal

Guidance for working in `Apps/Journal/`. The repo-root `CLAUDE.md` and
`coding-guide.md` still apply; this file adds Journal-specific context.

## What this app is

A journaling app (iPhone + iPad) where each captured thing becomes one **Card**.
iCloud sync is a hard requirement → **SwiftData with CloudKit mirroring**.

The app is **pre-product**: the real journaling UI is undecided. Today the root
is a **dev gallery**
(`Sources/Journal/Features/Settings/CaptureGalleryView.swift`) that launches
each capture component standalone. Read `docs/SPECIFICATION.md` for the full,
current state — keep it updated when behavior changes (see its Documentation
Policy; this is in addition to the repo-root `docs/SPECIFICATION.md`, which is
about distribution, not product behavior).

## Layout

- `Sources/Journal/` — app shell: `JournalApp`, creation/list/settings features,
  app-local components, sync helpers, notification UI, and app resources such as
  `Icon.icon`.
- `Sources/JournalModel/` — **shared data layer** (dynamic framework): `Card`, `Tag`,
  `Attachment`, `CardRelationship`, `Coordinate`, and `JournalStore` (the schema
  + the one shared-container factory). Linked by both the app and the widget;
  built extension-API-only.
- `Sources/JournalWidget/` — **WidgetKit extension** (`.appExtension`): `JournalWidgetBundle`
  (`@main`) + `LatestNoteWidget`, which reads recent cards from the shared store
  and shows the authored latest item, including doodle thumbnails when available.
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
- **SwiftData models obey CloudKit-mirroring constraints.** Every stored property
  optional-or-defaulted, no `.unique`, every relationship optional, inverse
  declared on one side only. Adding a non-optional property or a `.unique` will
  break CloudKit validation at launch.
- **The store is shared via an App Group; build it only through `JournalStore`.**
  The SwiftData store lives in the `group.app.muukii.journal` container so the app
  and the `JournalWidget` extension read the same database. `JournalStore`
  (`JournalModel`) is the single source of truth for the schema and container —
  the app and widget both call `JournalStore.makeModelContainer()`; never build a
  `ModelContainer` for journal data elsewhere. Models are `public` (the widget
  links them). After a write the app can refresh the widget with
  `WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)`
  (already wired into `CreationView.save()`). Widget views render a `Sendable`
  `NoteSnapshot`, never `Card` references.
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
