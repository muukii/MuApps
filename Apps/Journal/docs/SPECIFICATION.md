# Journal — Specification

The current, factual state of the `Journal` app. Update this whenever a
functional change lands (see [Documentation Policy](#documentation-policy)).

---

## Overview

`Journal` is a journaling app for iPhone and iPad. Each thing a user records —
text, a photo, a doodle, ambient sound, a Journaling Suggestion — becomes one
**Card**. iCloud sync across a user's devices is a hard product requirement, so
persistence is **SwiftData with CloudKit mirroring**.

### Project status

The app is **pre-product**: the real journaling UI is still being designed. What
exists today is:

- A working **SwiftData + CloudKit persistence stack** (the `Card` / `Tag` model
  graph, verified to initialize and pass CloudKit schema validation).
- Five **capture components**, each built as an isolated framework so it can be
  developed and exercised on its own, independent of the undecided UI.
- A **dev gallery** (`CaptureGalleryView`) that is the current app root — it
  launches each component standalone for on-device testing. This is scaffolding,
  **not the shipping entry point**.
- A **theming system** (`MuColor`) and a **Core Haptics lab** (`MuHaptics`).
- A **widget-ready structure**: the data layer lives in a shared `JournalModel`
  framework and the SwiftData store is in an App Group container, so the
  `JournalWidget` extension reads the same Cards as the app. A minimal "Recent
  Cards" widget ships as a scaffold proving the structure works end-to-end.

Because the product shell is undecided, capture components are deliberately
**persistence-agnostic**: each emits a plain `Sendable` value through a
`@MainActor @Sendable` callback and knows nothing about `Card`, SwiftData, or
iCloud. Wiring captures into persisted Cards is the next design step.

---

## Architecture

Tuist project (`Apps/Journal/Project.swift`) with an app target, a **widget
extension**, a shared **data-layer framework**, and several **Journal-local
static frameworks**. The frameworks live inside the app (not in the repo's
`Shared/`) because they are app-scoped, not cross-app.

```
Journal (app, app.muukii.journal)
├── JournalWidget      — WidgetKit extension (app.muukii.journal.JournalWidget)
│   └── JournalModel    (reads the shared store)
├── JournalModel       — data layer: Card/Tag/Coordinate + JournalStore
│                        (dynamic framework, linked by both app and widget)
├── MuColor            — color themes / palette + container views
├── MuHaptics          — Core Haptics pattern editor & engine (Lab)
├── CaptureText        — text note capture
├── CapturePhoto       — camera capture (depends on Capturer)
├── CaptureDoodle      — SwiftUI vector ink canvas (no extra deps)
├── CaptureAudio       — ambient sound recording (depends on AVFoundation)
└── CaptureSuggestions — Apple Journaling Suggestions picker demo
```

`JournalModel` is a **dynamic** framework (unlike the capture components, which
are static and app-only) because it is linked by *both* the app and the widget
extension; a dynamic framework embeds it once and lets the extension reference
it. It is built `APPLICATION_EXTENSION_API_ONLY` so it is safe to link into the
extension.

### Widget extension

`JournalWidget` (`product: .appExtension`, embedded into the app bundle by an
explicit target dependency) is a WidgetKit extension. Its single **Recent Cards**
widget (small / medium families) reads the most recent `Card`s directly from the
shared SwiftData store via `JournalStore.makeModelContainer()`, mapping each to a
`Sendable` `CardSnapshot` so the timeline entry and views stay free of the
persistence layer. The app can refresh it after a write with
`WidgetCenter.shared.reloadAllTimelines()`. It is a scaffold — the shipping
widget's content is still to be designed.

### Entitlements & capabilities

Declared in `Project.swift` on the app target:

- `com.apple.developer.icloud-container-identifiers` = `iCloud.app.muukii.journal`
- `com.apple.developer.icloud-services` = `CloudKit`
- `com.apple.security.application-groups` = `["group.app.muukii.journal"]` —
  backs the shared SwiftData store. Declared on **both** the app and the
  `JournalWidget` target so the two processes open the same database file.
- `aps-environment` = `$(APS_ENVIRONMENT)` — expanded per configuration
  (`development` for Debug, `production` for Release). Required so shipped builds
  receive CloudKit's silent pushes for background sync.
- `com.apple.developer.journal.allow` = `["suggestions"]` — lets
  `CaptureSuggestions` present the system Journaling Suggestions picker. Note the
  value is a **string array**, not a boolean; it must match what the App ID's
  Journaling Suggestions capability writes into the provisioning profile or
  signing fails.

The `JournalWidget` target carries the same App Group, iCloud container,
CloudKit, and `aps-environment` entitlements as the app — it opens the identical
CloudKit-mirrored store, so it needs the same access.

### Usage descriptions (Info.plist)

- `NSCameraUsageDescription` — CapturePhoto.
- `NSMicrophoneUsageDescription` — CaptureAudio.
- `UIBackgroundModes` = `["remote-notification"]` — lets SwiftData's CloudKit
  mirroring pull updates while backgrounded.

---

## Data Model

Defined in the **`JournalModel`** framework (so both the app and the widget can
read it). `JournalStore` owns the schema and the single shared container factory
(`makeModelContainer()`), which places the store in the App Group container
(`groupContainer: .identifier("group.app.muukii.journal")`) and mirrors it
through CloudKit (`cloudKitDatabase: .automatic`). The app calls it at launch and
the widget's timeline provider calls it to read Cards — never build a
`ModelContainer` for journal data anywhere else. The schema is `Card.self` +
`Tag.self`.

All models obey **CloudKit-mirroring constraints**: every stored property is
optional or has a default, no `.unique` attributes, and every relationship is
optional. A consequence is that uniqueness cannot be enforced — the same logical
record created on two devices can produce duplicate rows; de-duplication, if it
ever matters, is an app-level concern.

### `Card` — a single post

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Logical id; not unique-enforced (see above). |
| `createdAt` | `Date` | |
| `updatedAt` | `Date` | |
| `tags` | `[Tag]?` | Many-to-many; inverse declared on `Tag.cards`. |
| `location` | `Coordinate?` | `nil` = no location (not permitted or unavailable). |
| `title` | `String` | |
| `body` | `String` | |

The model is deliberately minimal and will grow as the journaling UI takes
shape.

### `Tag` — a label applied to many Cards

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | |
| `name` | `String` | |
| `createdAt` | `Date` | |
| `cards` | `[Card]?` | `@Relationship(inverse: \Card.tags)`. Declared on this side only. |

### `Coordinate` — a geographic point

A `Codable, Hashable, Sendable` struct (`latitude`, `longitude`) stored on `Card`
as an optional SwiftData composite attribute. Bridges to/from
`CLLocationCoordinate2D`. A present value always implies the user permitted
location use.

> **Not yet wired:** location *capture* (CLLocationManager +
> `NSLocationWhenInUseUsageDescription`) is not implemented — the model field
> exists but nothing populates it.

---

## Capture Components

Each is an isolated framework that emits a value type through a callback and owns
no persistence. The dev gallery hosts each in a standalone demo view.

### CaptureText → `CapturedText`

`TextCaptureView` — a self-contained multiline editor. Auto-focuses on appear,
shows a placeholder, and emits `CapturedText(text:)` via `onCommit` from a
toolbar **Save** button (disabled when the trimmed text is empty).

- `CapturedText`: `Sendable, Equatable` — `text: String`, `isEmpty` (whitespace-
  trimmed).

### CapturePhoto → `CapturedPhoto`

`PhotoCaptureView` — an in-place camera surface (live preview, shutter,
front/back flip) built on the **Capturer** library. Handles authorization states
(`unknown` / `authorized` / `denied` / `unavailable`) and emits the still through
`onCapture`.

- `CapturedPhoto`: `Sendable, Equatable` — `imageData: Data` (JPEG bytes),
  `pixelSize: CGSize`, lazy `image: UIImage?`.
- `CameraController` drives Capturer's async camera API; `CameraPreviewView`
  mounts Capturer's `PixelBufferView` in SwiftUI.

### CaptureDoodle → `DoodleDrawing`

`DoodleCanvasView(inkColor:onExport:)` — a **SwiftUI vector** ink canvas. Strokes
are stored as resolution-independent, **colorless** polylines (the ink is the
caller-supplied `inkColor`, applied at draw time, so changing the app theme
re-tints every doodle — including ones drawn earlier). Every point carries a
timestamp on a single shared timeline, so the doodle can be **replayed** at the
speed it was drawn (▶︎ button; a `TimelineView(.animation)` reveals strokes up to
the elapsed time). Replay **compresses long pauses**: any gap between consecutive
points over `0.35s` (almost always the pen-up time between strokes) is clamped to
that beat, so playback doesn't sit idle — the stored timestamps stay faithful;
only playback is reshaped. Stroke smoothing is ported from FluidGroup/Brightroom's
`EditingCanvas` (velocity-aware lag + streaming cubic Bézier, default strength
`0.92`). The toolbar is single-color: width slider, undo, replay, clear, export.

- `DoodleDrawing`: `Sendable, Equatable, Codable` — `strokes: [DoodleStroke]`,
  `canvasSize: CGSize`, `duration: TimeInterval`. `image(inkColor:scale:)`
  rasterizes a tinted thumbnail on demand.
- `DoodleStroke`: `points: [DoodlePoint]` (each `x, y, time`), `width: Double`.
- Supporting types: `DoodleCanvas` (controller), `DoodleStrokesView` (renderer),
  `InkSmoothing`, `StrokeSmoothing`, `DrawingGestureRecognizer` (timestamped),
  `TimedPoint`.

### CaptureAudio → `AudioRecording`

`AudioCaptureView` over `AmbientAudioRecorder` — records the whole ambient
soundscape to an AAC (`.m4a`) file in the temp directory via `AVAudioRecorder`,
exposing live duration and a normalized input level for a scrolling waveform.

- `AudioRecording`: `Sendable, Equatable` — `fileURL: URL` (temp dir; host must
  move it to keep it), `duration: TimeInterval`.
- `AmbientAudioRecorder`: `@MainActor @Observable` — `state` (`idle` /
  `recording` / `finished`), `duration`, `samples: [Float]` (rolling
  normalized-amplitude window, fixed length 48, ~2.4s at a 50ms poll). Static
  `requestPermission()` / `permission`. `start()` throws; `stop()` returns the
  `AudioRecording`. Level mapping is linear-in-dB above a −50dB silence floor so
  the meter tracks perceived loudness.

### CaptureSuggestions → `CapturedSuggestion`

`SuggestionCaptureView` — demos Apple's `JournalingSuggestionsPicker`. The picked
`JournalingSuggestion` is resolved (`CapturedSuggestion.resolve(from:)`) into a
flattened, `Sendable` value model.

- `CapturedSuggestion`: `Sendable, Equatable` — `title`, `dateInterval?`,
  `elements: [SuggestionElement]`.
- `SuggestionElement`: an enum whose cases carry genuinely different shapes
  (photo, song, podcast, media, workout, location, motion, contact, reflection),
  so rendering UI `switch`es over them.

**Platform constraints (important):**

- `JournalingSuggestions` and `HealthKit` ship only in the **device SDK**, absent
  from the Simulator SDK. All framework-touching code sits behind
  `#if canImport(JournalingSuggestions)`; the Simulator gets a placeholder. No
  explicit Tuist `.sdk` link (it would break Simulator builds) — Swift
  autolinking handles it.
- `JournalingSuggestions` is also absent from the **Mac (Designed for iPad)**
  runtime, so it is imported `@_weakLinked` in both files that import it (any
  plain `import` re-strengthens the autolink → dyld launch failure on Mac). A
  runtime guard (`ProcessInfo.isiOSAppOnMac`) shows the placeholder and erases the
  picker behind `AnyView` so its type metadata is never instantiated on Mac.
- Suggestions only appear on a **real device** with the Settings opt-in enabled,
  and the App ID needs the Journaling Suggestions capability so the managed
  profile carries the entitlement key. Min deployment iOS 26.1 (no `@available`
  gating needed).

---

## Supporting Frameworks

### MuColor — theming

A small palette/theme system applied app-wide.

- `Palette`: five seed colors (`tint`, `primaryContainer`, `onPrimaryContainer`,
  `secondaryContainer`, `onSecondaryContainer`) plus opacity-derived variants
  (`onPrimaryContainerVariant`, `outline`, `outlineVariant`, `tintRing`, …). No
  new hues are added beyond the five seeds. Colors are Display P3, declared via
  the `#hexColor` macro (the external `HexColorMacro` dependency).
- `Theme`: an `id` + display `name` + a **light** and **dark** `Palette` pair.
  Five themes: **Warm Cream** (default), **Soft Mocha**, **Midnight**, **Sage**,
  **Blush**. `Theme.palette(for:)` resolves the surface for the active
  `ColorScheme`; `Theme.with(id:)` resolves a persisted id, falling back to
  `.default`. Each theme adapts automatically to system Light/Dark mode.
- Container views `PrimaryContainer` / `SecondaryContainer` push a palette into
  the environment (`\.appPalette`) and apply background/foreground/tint.
  `PrimaryContainer(theme:)` resolves the theme's light/dark palette from the
  current color scheme at the root; nested containers inherit the resolved
  palette. App shape styles (`.appPrimaryContainer`, `.appSecondaryContainer`, …)
  read the palette from the environment so theme and color-scheme changes
  re-render the tree.
- `\.appPalette` is **public**, so any consumer can read the active palette to
  derive raw `Color`/`UIColor` values where a `ShapeStyle` won't do — e.g.
  configuring a `UINavigationBarAppearance` (see `appNavigationBarStyle`).

### MuHaptics — Core Haptics lab

A self-contained pattern editor + playback engine (reached via the gallery's
**Lab** section).

- `HapticPattern`: `Equatable, Sendable, Identifiable` — `name`, `events:
  [Event]` (each with `kind` transient/continuous, `time`, `duration`,
  `intensity`, `sharpness`). Computes `duration`, builds a `CHHapticPattern`, and
  can emit Swift source for a pattern. Ships presets (single tap, double tap,
  heartbeat, ramp up, …).
- `HapticEngine`: plays a `HapticPattern` or a raw AHAP dictionary; `isSupported`
  gates unsupported hardware.
- `HapticEditorView`: the lab UI.

---

## App Entry & Screens

- **`JournalApp`** (`@main`) — builds the `ModelContainer` for the `Card` + `Tag`
  schema with `ModelConfiguration(cloudKitDatabase: .automatic)`, and injects the
  persisted theme palette via `RootView` → `PrimaryContainer`.
- **`RootView`** — reads the persisted theme (`@AppStorage(JournalDefaults.themeID)`)
  and applies its palette, then hosts `CaptureGalleryView`.
- **`CaptureGalleryView`** (current app root, dev scaffolding) — a `List` with:
  - **Capture**: Text, Photo, Doodle, Ambient Sound, Suggestions.
  - **Lab**: Haptics.
  - **Storage**: Entries (SwiftData / iCloud) → `ListView`.
  - Toolbar → **Settings**.
  - Navigation-bar title and icons follow the active palette
    (`onPrimaryContainer` / `tint`) via `appNavigationBarStyle` (see below).
- **`appNavigationBarStyle(titleColor:iconColor:backgroundColor:)`**
  (`Sources/AppNavigationBarStyle.swift`) — recolors the enclosing
  `NavigationStack`'s title and icons (bar-button items + back chevron) by
  applying a per-instance `UINavigationBarAppearance`, reached via
  **SwiftUIIntrospect**. Uses the `@_spi(Advanced)` range predicate
  `.iOS(.v26...)` so it fires on iOS 26 *and every later OS* (plain `.iOS(.v26)`
  only matches when 26 is the current major, so it would no-op on iOS 27+).
  iOS 26+'s system (Liquid Glass) background is preserved unless an explicit
  `backgroundColor` is passed; the global appearance proxy is never touched.
- **`ListView`** — a `@Query` + `modelContext.insert` harness over `Card` that
  exists only to exercise the SwiftData + CloudKit stack end-to-end. Cards render
  in a two-column `LazyVGrid` of portrait tiles shaped like a sheet of paper
  (1 : 1.1414), filled with the active palette's `secondaryContainer`. Each tile
  is tilted by a small stable angle (±3°) derived from its `Card.id`, for a
  loosely hand-placed look. Not the real entries UI.
- **`SettingsView`** — a theme picker. Selecting a theme writes
  `JournalDefaults.themeID` (animated) and triggers selection haptic feedback.

> `Sources/EntryScreen.swift` is currently an empty stub (no functional content).

---

## Build & Run

This is a Tuist project; the `.xcodeproj` is generated. From the repo root:

```bash
tuist install
tuist generate
xcodebuild -workspace MuApps.xcworkspace -scheme Journal \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Each capture component also has its own scheme (`CaptureText`, `CapturePhoto`,
`CaptureDoodle`, `CaptureAudio`, `CaptureSuggestions`, `MuColor`, `MuHaptics`)
for building/running it in isolation.

**Simulator note:** this machine has no iPhone 16 simulator — use **iPhone 17 /
OS 27.0**. The `Capturer` dependency is a git submodule; ensure it is checked out
before generating.

### iCloud / CloudKit verification

The stack is runtime-verified on Simulator: `NSPersistentCloudKitContainer`
initializes against `iCloud.app.muukii.journal` (Private DB) and passes Apple's
`PFCloudKitOptionsValidator` (confirm via the simulator log line referencing
`containerIdentifier:iCloud.app.muukii.journal`). Mirroring engages even without
an iCloud account (schema validation runs; no actual sync).

**Before sync works on real devices:** create/let Xcode auto-create the
`iCloud.app.muukii.journal` container, run signed into iCloud to push the
**Development** schema, verify Record Types in the CloudKit Console, test on two
physical devices, then **Deploy Schema to Production** before any
Release/TestFlight build (TestFlight + App Store use the Production environment
only).

---

## Documentation Policy

Update this file when a change affects what a user can do or see in the Journal
app — new/changed/removed capture components, model changes, screens, themes,
entitlements, or platform behavior. Skip it for pure refactors, style changes, or
bug fixes that restore already-documented behavior.

This app-local spec covers Journal's product behavior. The repo-root
`docs/SPECIFICATION.md` covers cross-app distribution (Ad Hoc OTA, App Store
Connect) and is a separate concern.
