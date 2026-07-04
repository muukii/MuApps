# Journal — Specification

The current, factual state of the `Journal` app. Update this whenever a
functional change lands (see [Documentation Policy](#documentation-policy)).

---

## Overview

`Journal` is a journaling app for iPhone and iPad. Each thing a user records —
text, a photo, a doodle, Bauhaus grid artwork, ambient sound, a Journaling
Suggestion — becomes one **Card**. iCloud sync and vault collaboration are hard
product requirements, so the app is moving to **per-vault SwiftData stores with
CloudKit mirroring disabled** and explicit CloudKit sync through `JournalVault`.

### Project status

The app is **pre-product**: the real journaling UI is still being designed. What
exists today is:

- A working **JournalVault persistence foundation**: a catalog store, per-vault
  content stores, `CardEdge` / `Card` / `Attachment` rows, outbox mutations, and
  an explicit CloudKit sync boundary.
- Six **capture components**, each built as an isolated framework so it can be
  developed and exercised on its own, independent of the undecided UI.
- A **vault-first app shell** (`VaultSelectionView` → `CreationView`) that asks
  for a vault before composing, then writes text, link, photo, audio, doodle, and
  Bauhaus Cards into the selected `VaultInstance` through card-specific editors,
  plus a **dev gallery**
  (`CaptureGalleryView`) that launches each component standalone for on-device
  testing. The dev gallery is scaffolding, **not the shipping entry point**.
- A **theming system** (`MuColor`) and **Core Haptics labs** (`MuHaptics`).
- A **vault-selectable widget**: `JournalWidget` lets each widget instance choose
  one vault and reads the latest card from that vault's App Group store.

Because the product shell is undecided, capture components are deliberately
**persistence-agnostic**: each emits a plain `Sendable` value through a
`@MainActor @Sendable` callback and knows nothing about `Card`, SwiftData, or
iCloud. The app shell converts those values into `CardEditDraft` payloads
before persistence sees them.

---

## Architecture

Tuist project (`Apps/Journal/Project.swift`) with an app target, a **widget
extension**, a shared **data-layer framework**, and several **Journal-local
static frameworks**. The frameworks live inside the app (not in the repo's
`Shared/`) because they are app-scoped, not cross-app. All Journal target source
roots are grouped under `Apps/Journal/Sources/<TargetName>/`; the app icon
package is `Apps/Journal/Sources/Journal/Icon.icon`. The target and module names
remain `Journal`; the user-facing app bundle display name is `Tinycurve`,
and the WidgetKit extension bundle display name is `Tinycurve Widget`.

```
Journal (app, app.muukii.journal)
├── JournalWidget      — WidgetKit extension (app.muukii.journal.JournalWidget)
│   └── JournalVault    (vault catalog/content reader)
├── JournalModel       — data layer: Card/Tag/Attachment/CardRelationship/Coordinate
│                        + JournalStore
│                        (legacy migration/local tooling framework)
├── JournalVault       — vault catalog/content stores + explicit CloudKit sync
├── MuColor            — color themes / palette + container views
├── MuHaptics          — Core Haptics pattern editor, tap sequencer & engine (Lab)
├── CaptureText        — text note capture
├── CapturePhoto       — camera capture (AVFoundation)
├── CaptureDoodle      — SwiftUI vector ink canvas (depends on CoreHaptics)
├── CaptureBauhaus     — 5 x 5 Bauhaus-style grid composer
├── CaptureAudio       — ambient sound recording (depends on AVFoundation)
└── CaptureSuggestions — Apple Journaling Suggestions picker demo
```

`JournalVault` is the app shell's active persistence framework and the widget's
vault reader. `JournalModel` remains a legacy migration/local tooling framework.
The app target no longer opens it for startup migration. It is built
`APPLICATION_EXTENSION_API_ONLY` for compatibility with narrow extension-side
tooling, but product widget behavior should not read it.

### Vault migration direction

`JournalApp` creates `JournalVaultRuntime` on launch. The runtime starts the
sync layer and leaves the catalog empty when CloudKit recovery finds no owned or
accepted shared vaults. That empty catalog is the new-user state; the app does
not create preset vaults at install time and does not open the old App Group
SwiftData SQLite store.

Product migration should be implemented as a CloudKit operation owned by the
sync layer: query legacy CloudKit records / CKAssets, write the new records into
a migration target vault zone only when legacy content exists, then let the
vault sync import materialize those records into `VaultContentStore`. The
migration should run only when the target vault has no cards, so existing vault
content is never merged with legacy data. Local-only SwiftData SQLite import can
exist only as developer tooling; it is not the product migration path.

### Widget extension

`JournalWidget` (`product: .appExtension`, embedded into the app bundle by an
explicit target dependency) is a WidgetKit extension. Its single **Latest Note**
widget supports Home Screen small / medium / large families plus Lock Screen
inline / circular / rectangular accessory families. It uses
`AppIntentConfiguration` so each widget instance can choose one vault from
`VaultCatalogStore`; already-placed widgets with no explicit vault fall back to
the first catalog vault.

The timeline provider opens the configured vault's `VaultContentStore` from the
App Group and fetches a small recent `Card` window sorted by `createdAt`
descending. It resolves visibility through `CardEdge`: parent cards that have
children are skipped so a multi-card thread save displays the authored last
visible card instead of its root. It shows kind-aware content: text cards use
`Card.body` (falling back to `Untitled`), doodle and Bauhaus cards use mirrored
attachment thumbnails only when those optional bytes exist, and the other media
cards still show a modality label. The Home Screen families show the selected
vault title, latest-card body/thumbnail, and relative timestamp; the Lock Screen
accessory families use short labels or symbols that fit the tighter surfaces.
It maps the `Card` to a `Sendable` `NoteSnapshot` so the timeline entry and
views stay free of live SwiftData model references, capture frameworks, and
media files; it shows an empty state when there are no vaults or when the chosen
vault has no cards.

New card saves and saved-card edits request
`WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)` so
configured widgets refresh promptly. The 15-minute periodic timeline refresh
remains only for relative-date freshness. Future optimization can denormalize
latest-card previews into `VaultSummary`, but current product behavior reads the
selected vault store directly.

### Entitlements & capabilities

Declared in `Project.swift` on the app target:

- `com.apple.developer.icloud-container-identifiers` = `iCloud.app.muukii.journal`
- `com.apple.developer.icloud-services` = `CloudKit`
- `com.apple.security.application-groups` = `["group.app.muukii.journal"]` —
  backs the vault store layout and widget access to configured vaults. Declared
  on **both** the app and the `JournalWidget` target.
- `aps-environment` = `$(APS_ENVIRONMENT)` — expanded per configuration
  (`development` for Debug, `production` for Release). Required so shipped builds
  receive CloudKit's silent pushes for background sync.
- `com.apple.developer.journal.allow` = `["suggestions"]` — lets
  `CaptureSuggestions` present the system Journaling Suggestions picker. Note the
  value is a **string array**, not a boolean; it must match what the App ID's
  Journaling Suggestions capability writes into the provisioning profile or
  signing fails.

The `JournalWidget` target carries the same App Group, iCloud container,
CloudKit, and `aps-environment` entitlements as the app. Its live timeline read
is local App Group storage; CloudKit access remains available for future
extension-side recovery or summary refresh work.

### Usage descriptions (Info.plist)

- `NSCameraUsageDescription` — CapturePhoto.
- `NSPhotoLibraryUsageDescription` — choosing an existing Photos image for a
  photo card through the system picker.
- `NSMicrophoneUsageDescription` — CaptureAudio.
- `NSLocationWhenInUseUsageDescription` — automatic location attachment for
  newly authored cards when the Journal setting is enabled.
- `UIBackgroundModes` = `["remote-notification"]` — lets the explicit CloudKit
  sync layer wake for remote change notifications while backgrounded.

---

## Data Model

Active app data lives in **`JournalVault`**. SwiftData is local persistence and
SwiftUI observation only; every vault content store is opened with
`cloudKitDatabase: .none`. CloudKit rows, assets, zones, shares, and remote
imports belong to the CloudKit sync coordinator.

The legacy **`JournalModel`** schema still exists for migration and local
tooling. New app UI and product widget code must not write to it.

### `VaultInstance` — UI-facing vault object

Each vault has one UI-facing `VaultInstance` in the app process. It owns the
vault's `VaultContentStore`, cached outbox count, foreground sync interest, and
future permission/share state. App screens use the selected `VaultInstance`
rather than reaching for CloudKit transport objects or opening their own
`ModelContainer`.

### `VaultContentStore` — one vault database

Each vault has its own SQLite store and media directory under the App Group
layout:

```text
Journal/
  catalog.sqlite
  Vaults/
    <vault-id>/
      store.sqlite
      media/
      sync-state/
```

`VaultContentStore.createThread(cards:)` writes a root `CardEdge` plus child
edges in one transaction. The same transaction writes `PendingMutation` rows, so
local content never exists without a pending CloudKit upload.

### `Card` — a content atom

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Unique inside the vault store. Legacy migration preserves old card IDs. |
| `kindRawValue` | `String` | Stored/synced modality string. `kind` maps unknown values to `.unknown`. |
| `body` | `String` | Text content for `.text`; canonical URL string for `.link`; media cards keep this empty. |
| `createdAt` | `Date` | |
| `updatedAt` | `Date` | |
| `location` | `Coordinate?` | `nil` = no location. |

### `CardEdge` — a card placement in the vault tree

`CardEdge` is the fractal structure for both roots and children. A root edge has
`parentEdgeID == nil`; children point to another edge. A linear thread is a root
edge plus ordered child edges, and future mind-map layouts can attach layout data
without changing `Card`.

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Unique edge id. Migration derives deterministic edge IDs from legacy card/relationship IDs. |
| `cardID` | `UUID` | Referenced `Card`. |
| `parentEdgeID` | `UUID?` | Parent edge in the same vault, or `nil` for roots. |
| `sortIndex` | `Int` | Order among siblings. |
| `layout` | `Data?` | Reserved layout metadata. |
| `createdAt` | `Date` | |
| `updatedAt` | `Date` | |

### `Attachment` — media metadata for a Card

Attachment bytes live as files in the vault's `media/` directory. The row and
file share the same vault boundary, and `CloudKitVaultSyncEngine` uploads the
file as a CKAsset when a local file exists.

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Unique attachment id and file name. Legacy migration preserves old attachment IDs. |
| `cardID` | `UUID` | Referenced `Card`. |
| `kindRawValue` | `String` | `.photo`, `.audio`, `.doodle`, `.bauhaus`, or unknown raw value. |
| `byteSize` | `Int` | Size of the on-disk file at attach time. |
| `thumbnail` | `Data?` | Optional small preview data. |
| `createdAt` | `Date` | |

### `Coordinate` — a geographic point

A `Codable, Hashable, Sendable` struct (`latitude`, `longitude`) stored on `Card`
as an optional SwiftData composite attribute. Bridges to/from
`CLLocationCoordinate2D`. A present value always implies the user permitted
location use.

Location capture is wired into `CreationView` as an app-wide default controlled
by Settings. When enabled (the default), newly authored drafts request a
one-shot coordinate lazily and store the resolved `Coordinate` on the draft.
Turning the setting off removes location from in-progress drafts. Saving uses the
coordinate already attached to each draft, and still saves the card without a
location when access is denied or no fix is available.

---

## Capture Components

Each is an isolated framework that emits a value type through a callback and owns
no persistence. The dev gallery hosts each in a standalone demo view; the
compose detail editors also host Photo, Doodle, Bauhaus, and Ambient Sound and
convert their callbacks into `CardEditDraft` payloads. Text composition uses an
app-shell `TextEditor` bound directly to `CardEditDraft.text`; Link composition
uses an app-shell URL field and LinkPresentation preview over the same draft
body slot, so typed changes are reflected in the draft immediately.

### CaptureText → `CapturedText`

`TextCaptureView` — a self-contained multiline editor. Auto-focuses on appear,
shows a placeholder, and emits `CapturedText(text:)` via `onCommit` from a
toolbar **Save** button (disabled when the trimmed text is empty).

- `CapturedText`: `Sendable, Equatable` — `text: String`, `isEmpty` (whitespace-
  trimmed).

### CapturePhoto → `CapturedPhoto`

`PhotoCaptureView` — an in-place camera surface (live preview, shutter,
front/back flip) built directly on AVFoundation. Handles authorization states
(`unknown` / `authorized` / `denied` / `unavailable`) and emits the still through
`onCapture`.

- `CapturedPhoto`: `Sendable, Equatable` — `imageData: Data` (JPEG bytes),
  `pixelSize: CGSize`, lazy `image: UIImage?`.
- `CameraController` owns the `AVCaptureSession`, camera input, and still-photo
  output; `CameraPreviewView` mounts an `AVCaptureVideoPreviewLayer` in SwiftUI.

### CaptureDoodle → `DoodleDrawing`

`DoodleCanvasView(inkColor:initialDrawing:onExport:onChange:)` — a **SwiftUI
vector** ink canvas. Strokes are stored as resolution-independent, **colorless**
polylines (the ink is the caller-supplied `inkColor`, applied at draw time, so
changing the app theme re-tints every doodle — including ones drawn earlier).
`initialDrawing` restores existing vector strokes into the canvas, scales them
to the current canvas size, and appends new strokes after the existing replay
timeline. Every point carries a timestamp on a single shared timeline, so the
doodle can be **replayed** at the speed it was drawn (▶︎ button; a
`TimelineView(.animation)` reveals strokes up to the elapsed time). Replay
**compresses long pauses**: any gap between consecutive
points over `0.35s` (almost always the pen-up time between strokes) is clamped to
that beat, so playback doesn't sit idle — the stored timestamps stay faithful;
only playback is reshaped. The default brush is a strong custom **streamline**
engine rather than PencilKit: timestamped coalesced touches flow through an
incremental trajectory filter and streaming spline while the finger is down. The
visible live centerline is the saved centerline: lifting the finger commits the
current live points as-is, with no full-stroke refit, primitive snap, or catch-up
tail that would move already-drawn geometry. Width is velocity-shaped from the
same emitted timeline: each point stores an optional rendered width, fast spans thin out, stroke tips
taper lightly, and the renderer draws dense overlapping round segments so
tapering doesn't fold into a broken outline at tight turns.
Default brush width is `3pt`. While drawing, supported devices bracket each
stroke with light touch-down/lift taps and keep the in-stroke Core Haptics
continuous texture light while its intensity and sharpness follow finger speed;
replay surfaces skip the touch boundary taps and run only the speed-shaped
texture along the compressed playback timeline. Unsupported hardware, including
Simulator, no-ops.
The drawable surface is fixed to the same 4:5 portrait paper proportion as journal cards
(`width / height = 4 / 5`), and the toolbar is single-color: width slider,
undo, replay, clear, and export when `onExport` is supplied. When `onChange` is
supplied, the canvas emits the current
`DoodleDrawing?` after committed stroke changes, undo, or clear so hosts can
auto-save drafts.

- `DoodleDrawing`: `Sendable, Equatable, Codable` — `strokes: [DoodleStroke]`,
  `canvasSize: CGSize`, `duration: TimeInterval`. `image(inkColor:scale:)`
  rasterizes a tinted thumbnail on demand; `DoodleDrawingView` renders the saved
  vector value directly as SwiftUI content.
- `DoodleStroke`: `points: [DoodlePoint]` (each `x, y, time`, optional
  point-level `width`), `width: Double` base brush width.
- Supporting types: `DoodleCanvas` (controller), `DoodleStrokesView` (renderer),
  `StrokeSmoothing` (fixed streamline pipeline), `DoodleDrawingHaptics`,
  `DrawingGestureRecognizer` (timestamped), `TimedPoint`.

### CaptureBauhaus → `BauhausGridDocument`

`BauhausGridCaptureView(initialDocument:onChange:onExport:)` — a SwiftUI grid
composer for Bauhaus-style geometric artwork. The canvas is a fixed **5 x 5**
grid of square cells. Tapping a cell presents a native shape picker sheet; the
user chooses one of the prepared primitives (square, filled circle, padded
circle, four arc-on-edge semicircles, four diameter-on-edge semicircles, four
quarter-circles, and four diagonal triangles), and the selected
shape/background colors are applied to that cell. Compact swatch rows choose the
active primitive and cell background colors, the trash action clears the whole
artwork, and an optional export callback lets hosts finish the capture
explicitly. The picker groups primitives by family in fixed four-column rows so
rotational variants stay visually aligned while the sheet adapts to device
width. Every cell edit and clear emits the current `BauhausGridDocument` through
`onChange`. New empty documents record a replay timeline as cells are set or the
grid is cleared; documents decoded from older final-only artwork stay static
unless the user clears the grid and starts again. Cell and swatch selection use
selection haptics, shape application and clearing use light impact haptics, and
the optional export action uses success feedback.
Saved Bauhaus replay starts with a very short empty-grid beat, places every
authored event on the same brisk playback interval, and introduces each tile
with a bounce while preserving the stored authored event timeline. Tile opacity
and spring scale come from one shared motion sampler so the live SwiftUI replay
and generated mp4 use the same per-frame values.

- `BauhausGridDocument`: `Sendable, Equatable, Codable` — `artwork` is the
  canonical final grid for static rendering and editing; optional `replay`
  stores the authored event timeline from an empty grid. The decoder accepts
  old `BauhausGridArtwork` JSON as `artwork` with `replay == nil`.
- `BauhausGridReplay`: `Sendable, Equatable, Codable` — time-ordered
  `BauhausGridReplayEvent` values plus `duration`. Replaying applies each
  `BauhausGridReplayAction` to an empty grid up to the requested time.
- `BauhausGridArtwork`: `Sendable, Equatable, Codable` — row-major 25-cell
  storage where each cell is either empty or a `BauhausTile`. `BauhausGridArtworkView`
  renders the saved grid directly as SwiftUI content.
- `BauhausGridPosition`: `Sendable, Equatable, Hashable, Codable, Identifiable`
  — a stable zero-based row/column coordinate inside the 5 x 5 grid.
- `BauhausTile`: `Sendable, Equatable, Codable` — `shape: BauhausShapeKind`,
  `shapeSwatch: BauhausSwatch`, `backgroundSwatch: BauhausSwatch`.
- `BauhausShapeKind`: prepared geometric primitives that each fit inside one
  square cell, including both a filled circle and a padded circle that leaves a
  small amount of visible cell background around the mark.
- `BauhausSwatch`: a fixed Codable content-color slot set (`slot1...slot7`).
  These are authored artwork tokens, not app theme colors or concrete color
  names; the slot raw values are also the persisted JSON values.
- `BauhausColorPalette`: a Bauhaus-specific light/dark palette. Each resolved
  appearance separates authored `BauhausSwatchColors` from non-authored
  `BauhausCanvasChrome` such as paper, empty-cell, grid-line, border, and
  thumbnail shadow colors.

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

- `Palette`: six seed colors (`tint`, `onTint`, `primaryContainer`,
  `onPrimaryContainer`, `secondaryContainer`, `onSecondaryContainer`) plus
  opacity-derived variants (`onPrimaryContainerVariant`, `outline`,
  `outlineVariant`, `tintRing`, …). `onTint` is the foreground color for text and
  icons displayed directly on a tint/accent surface. No new hues are added beyond
  the seeds. Colors are Display P3 named colors in namespaced groups under
  `Resources/MuColor/Assets.xcassets`, such as `Theme/WarmCream/Tint`. Each
  colorset stores the light value as Any and the dark value as the Dark
  appearance; Swift only maps each `Theme` to its stable asset namespace and
  resolves the requested `ColorScheme` through asset traits.
- `Theme`: an `id` + display `name` + a **light** and **dark** `Palette` pair.
  Eleven themes: **Warm Cream** (default), **Soft Mocha**, **Midnight**,
  **Sage**, **Blush**, **Citrus**, **Lagoon**, **Berry**, **Vermilion**,
  **Cobalt**, and **Forest**. `Theme.palette(for:)`
  resolves the surface for the active
  `ColorScheme`; `Theme.with(id:)` resolves a persisted id, falling back to
  `.default`. Each theme adapts to the active Light/Dark mode, which can either
  follow the device setting or be overridden from Settings for Journal.
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

### MuHaptics — Core Haptics labs

A self-contained pattern editor, tap sequencer, and playback engine (reached via
the gallery's **Lab** section).

- `HapticPattern`: `Equatable, Sendable, Identifiable` — `name`, `events:
  [Event]` (each with `kind` transient/continuous, `time`, `duration`,
  `intensity`, `sharpness`). Computes `duration`, builds a `CHHapticPattern`, and
  can emit Swift source for a pattern. Ships presets (single tap, double tap,
  heartbeat, ramp up, …).
- `HapticTapSequence`: `Codable, Equatable, Sendable, Identifiable` — `name`,
  `taps: [Tap]`, where each tap stores `time`, `intensity`, and `sharpness`.
  It is the haptic analogue of a doodle timeline: the user taps out a rhythm and
  the sequence converts to a playable `HapticPattern`.
- `HapticEngine`: plays a `HapticPattern` or a raw AHAP dictionary; `isSupported`
  gates unsupported hardware.
- `HapticEditorView`: the lab UI.
- `HapticTapSequencerView`: a **Haptic Doodle** lab that records tap timing from
  touch-down on a large tap surface, previews the timeline, supports undo/clear,
  plays the sequence through Core Haptics, and exports Swift source for the
  captured sequence.

---

## App Entry & Screens

- **`JournalApp`** (`@main`) — builds `JournalVaultRuntime` and injects the
  persisted theme palette via `RootView` → `PrimaryContainer`. It does not open
  or inject the legacy `ModelContainer`.
- **`RootView`** — reads the persisted theme (`@AppStorage(JournalDefaults.themeID)`)
  and appearance preference
  (`@AppStorage(JournalDefaults.appearancePreferenceID)`), applies the palette,
  and requests the chosen scene color scheme. `System` follows the device
  appearance; `Light` and `Dark` override it for Journal. It is also the root
  router. On a fresh install, it starts in **Loading** while
  `JournalVaultRuntime` resolves initial vault availability: if iCloud is
  available, it performs the first CloudKit vault discovery pass; if iCloud is
  unavailable or unused, it resolves to local-only state; if iCloud is
  temporarily unavailable or cannot be determined, it resolves with deferred
  CloudKit recovery instead of blocking forever. A resolved decision records
  `JournalDefaults.hasResolvedInitialVaultAvailability`. Later launches restore
  a route immediately from that cached decision and
  `JournalDefaults.hasCompletedOnboarding`, while `JournalVaultRuntime` still
  starts and runs recovery in the background. Existing local or recovered vault
  state routes to the existing-user vault flow (`VaultSelectionView` →
  `CreationView`). If no vault state exists and onboarding has not been
  completed, it routes to **New User** onboarding. Completing onboarding records
  `@AppStorage(JournalDefaults.hasCompletedOnboarding)` and then enters the
  vault picker, where the user can create the first vault. When initial iCloud
  recovery was deferred, the vault picker shows a compact diagnostic banner and
  Settings' debug-only **Vault Runtime** screen shows the last availability
  resolution. It also owns the
  scene-local `JournalNotificationCenter` and wraps the app content in
  `JournalNotificationHost`, which injects that model through the SwiftUI
  environment and overlays app-wide bottom capsule notifications above the
  current screen. Incoming CloudKit vault invitations are bridged from UIKit
  scene metadata into `JournalVaultRuntime.acceptShare(metadata:)`; success
  completes onboarding if needed and returns the user to the vault picker.
- **`VaultSelectionView`** — the post-onboarding entry screen. It reads
  `JournalVaultRuntime.vaults`, shows the catalog in picker order as a standard
  SwiftUI `List`, and calls `JournalVaultRuntime.selectVault(_:)` before
  entering the composer. The toolbar
  also opens a **New Vault** sheet; creating a vault calls
  `JournalVaultRuntime.createVault(title:)`, seeds the local vault store, reloads
  the catalog, opens the new vault, and then enters the composer. Settings are
  reachable from this screen so app-wide preferences remain available before a
  vault is active. Owned vault rows also show an **Invite People** affordance
  that prepares the vault's saved zone-wide CloudKit share and then presents the
  system `UICloudSharingController` with private invite / read-write options;
  participant vault rows do not offer invite issuance.
- **`OnboardingView`** — the first-run introduction, also re-showable on demand
  from Settings. Four horizontally-paged screens (`TabView` with
  `.tabViewStyle(.page)`) plus a fixed **Get Started** / **Next** call-to-action
  and a **Skip** affordance on every page but the last:
  1. **Welcome** — a decorative `CardSurface` stating the core idea ("Every little
     thing becomes a card") over a short welcome blurb.
  2. **Capture methods** — the six modalities (Text, Link, Photo, Doodle,
     Ambient Sound, Suggestions) as icon + name + one-line summary.
  3. **Permissions** — optional priming for Camera, Microphone, and Location. Each
     row shows the live authorization status and an **Allow** button that triggers
     the system prompt on demand (`AVCaptureDevice.requestAccess(for:)`,
     `AmbientAudioRecorder.requestPermission()`, `LocationManager.requestAuthorization()`);
     the user can advance without granting anything.
  4. **Theme** — a grid of theme tiles bound to the same `JournalDefaults.themeID`
     key, so a selection applies app-wide and re-tints the onboarding immediately.

  The view is presentation-agnostic — it reports completion through an
  `onComplete` closure and never writes `hasCompletedOnboarding` itself — and
  wraps its body in its own `PrimaryContainer` keyed to the stored theme so the
  palette resolves whether shown inline (first run) or over the app (Settings
  cover).
- **`CreationView`** — the selected-vault compose screen: a date header
  (`DateView`) showing today's weekday, month, and day, then
  a vertical `ScrollView` of card-shaped draft summaries. The header is rendered
  with the standard `Date.FormatStyle` field selection, so its field order and
  separators follow the user's locale (en: "Sat, Jun 27"; ja: "6月27日(土)").
  Drafts render through the same adaptive saved-entry summary card wrapper used
  by Entries; the wrapper still owns the 4:5 paper aspect ratio, footer, tilt, and
  modality-specific summary layout, while draft-only media payloads are fed in
  directly instead of being loaded from attachment files. Tapping a text card
  opens a native **Text** sheet with a focused `TextEditor`. Tapping a photo card
  opens a native **Photo** sheet, showing the existing
  `CapturedPhoto` with **Retake Photo** or `PhotoCaptureView` for a new shot.
  Tapping a doodle card opens a dedicated full-screen **Doodle** canvas that
  reopens the existing `DoodleDrawing` in `DoodleCanvasView` so new strokes append
  to the same vector drawing. Tapping a Bauhaus card opens a native **Bauhaus**
  sheet that restores the existing `BauhausGridDocument`; tapping a cell presents
  the shape picker sheet, and choosing a shape applies it into the selected 5 x 5
  grid cell while recording replay events when the document has a replay
  timeline. Tapping a link card opens a native **Link** sheet with URL keyboard
  input; values such as `example.com` are normalized to HTTPS before save, and
  valid web URLs show iOS's native LinkPresentation preview in the composer.
  Tapping an audio card opens a native **Voice Record** sheet, showing
  **Play** and **Record Again** for an existing
  `AudioRecording` or `AudioCaptureView` for a new take. The bottom composer
  controls put the concrete content-type icons — Text, Link, Camera, Photos,
  Doodle, Bauhaus, and Voice — in separated Liquid Glass buttons inside one shared
  `GlassEffectContainer`, with the save action remaining a separate prominent
  glass button. Tapping one of those quick-capture icons presents the matching
  native sheet or picker. Text opens the last untouched text placeholder when one
  exists; otherwise it creates a new text draft and opens the Text sheet. Text,
  Doodle, and Bauhaus sheets reflect edits into the draft as the user works and
  rely on interactive dismissal rather than **Done** or **Cancel** buttons. Camera
  and Voice create/reuse a draft only after capture finishes, then dismiss back
  to the composer. Photos opens Apple's system photo picker; after the selected
  image is loaded and normalized into the app's `CapturedPhoto` payload, the
  composer creates/reuses the same photo draft type used by camera capture. If a
  selected image cannot be loaded, the composer leaves drafts unchanged and shows
  a persistent failure notification. Doodle and Bauhaus present native sheets at
  the large detent and resolve a draft on the first non-empty canvas/grid change,
  reusing the first untouched text placeholder when possible and
  restoring/removing that quick draft if the canvas/grid is cleared. The doodle
  canvas and Bauhaus grid auto-sync committed changes into the draft; there is no
  separate save button for those visual editors. The glass up-arrow converts the
  current draft cards into `VaultContentStore.CardDraft` values, saves them
  through the selected `VaultInstance` as one root `CardEdge` tree, then clears
  the composer.
  A successful save shows a transient bottom capsule notification ("Saved to
  Journal") with success haptics; if saving fails, the draft remains on screen
  and a persistent bottom capsule notification explains that the save did not
  complete with failure haptics. Notifications fade, blur, and scale in place
  with a slight bounce instead of sliding from an edge.
  The save button is disabled until every draft can be persisted (text requires
  non-empty trimmed text, link requires a valid HTTP(S) URL, and media kinds
  require a captured payload). Existing-Card continuation selection is not wired
  yet; this composer creates a new thread from the first draft.
  Toolbar links back to vault selection, to the vault-backed entries list
  (`SavedListView`), and to Settings. Capture demos are
  kept in the dev gallery rather than Settings; suggestions remain a dev-gallery
  component rather than a compose-surface card kind.
- **`CaptureGalleryView`** (dev scaffolding, not currently wired into the app
  root) — a `List` with:
  - **Capture**: Text, Photo, Doodle, Bauhaus Grid, Ambient Sound, Suggestions.
  - **Lab**: Haptics, Haptic Doodle in Debug builds only.
  - **Storage**: Entries (vault store) → `SavedListView`.
  - Toolbar → **Settings**.
  - Navigation-bar title and icons follow the active palette
    (`onPrimaryContainer` / `tint`) via `appNavigationBarStyle` (see below).
- **`appNavigationBarStyle(titleColor:iconColor:backgroundColor:)`**
  (`Sources/Journal/Components/AppNavigationBarStyle.swift`) — recolors the enclosing
  `NavigationStack`'s title and icons (bar-button items + back chevron) by
  applying a per-instance `UINavigationBarAppearance`, reached via
  **SwiftUIIntrospect**. Uses the `@_spi(Advanced)` range predicate
  `.iOS(.v26...)` so it fires on iOS 26 *and every later OS* (plain `.iOS(.v26)`
  only matches when 26 is the current major, so it would no-op on iOS 27+).
  iOS 26+'s system (Liquid Glass) background is preserved unless an explicit
  `backgroundColor` is passed; the global appearance proxy is never touched.
- **`SavedListView`** — a vault-backed entries list over the selected
  `VaultInstance`. It reads `CardEdge`, `Card`, and `Attachment` rows from
  the selected vault container, creates value snapshots, groups root edges into
  local-calendar day sections, and displays them as 4:5 `CardSurface` tiles. Child
  edges are shown in the pushed detail view as a flattened subtree; grid tiles
  are matched transition sources so opening a detail view uses the system zoom
  navigation transition from the tapped card. Link cards
  use iOS's LinkPresentation preview in both tiles and detail cards, fetching
  metadata at display time and caching it for the app session. Media previews
  prefer the vault media file when it exists and fall back to attachment
  thumbnails or a modality placeholder. The list listens for
  `VaultMediaFileChange` notifications for the selected vault and reloads snapshots
  when files arrive. Saved cards can be edited from a grid tile's context menu or
  from each detail card's pencil button. Editing rehydrates the saved card into
  `CardEditDraftEditor`, requires the full media file for media cards, and saves
  back through `VaultContentStore.updateCard(cardID:with:)`; thumbnails are not
  used as lossy edit sources. Legacy saved-entry export/share UI was removed with
  the migration and still needs to be rebuilt against `VaultInstance` snapshots.
- **`SettingsView`** — a theme picker, an **Appearance** picker, a **Location**
  toggle for automatic location attachment, a **Widgets** section with an **Add
  Widgets** guide, optional Debug-only **Vault Runtime** and Lab links, and About
  actions. Settings is a grouped `Form`, but every cell background opts into the
  active `MuColor` secondary container because SwiftUI form rows do not inherit
  the app theme surface automatically. Selecting a theme writes
  `JournalDefaults.themeID` (animated) and triggers selection haptic feedback.
  The Appearance segmented picker writes
  `JournalDefaults.appearancePreferenceID`; **System** follows the device
  setting, while **Light** and **Dark** request a fixed scene color scheme for
  Journal and update the theme palette immediately. The **Attach Location**
  toggle writes `JournalDefaults.shouldAttachLocationToNewCards`; it defaults on,
  and when disabled new draft cards are saved without location metadata. **Add
  Widgets** opens a Settings detail screen with an illustrated header and
  step-by-step instructions for adding Tinycurve to the Home Screen, Lock Screen
  below the clock, and StandBy. The guide frames the widget as showing the
  latest card in a chosen vault.
  Capture demos are intentionally hidden from Settings. In Debug builds, **Lab**
  links to Haptics and Haptic Doodle so those tools can be tried from the current
  app root; Release builds omit the Lab section. An **About** section has
  **Privacy Policy**, which opens an in-app policy explaining local storage,
  iCloud Private Database sync, optional permissions, sharing, widgets, and the
  absence of developer-operated analytics/ads/tracking, plus **Show
  Onboarding**, which re-presents `OnboardingView` in a `fullScreenCover`;
  dismissing it returns to the app without changing `hasCompletedOnboarding`.

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
`CaptureDoodle`, `CaptureBauhaus`, `CaptureAudio`, `CaptureSuggestions`,
`MuColor`, `MuHaptics`) for building/running it in isolation.

**Simulator note:** this machine has no iPhone 16 simulator — use **iPhone 17 /
OS 27.0**.

### iCloud / CloudKit verification

The active app shell disables SwiftData CloudKit mirroring for vault stores.
CloudKit verification now belongs to `CloudKitVaultSyncEngine`: zone creation,
record upload/download, CKAsset file transfer, subscriptions, share creation,
share invitation acceptance, and shared-database imports. The app runtime now
uses `CloudKitVaultSyncEngine`; `LoggingVaultSyncEngine` remains for previews,
debug probes, and narrow tests.
On every launch, the runtime should kick a lightweight CloudKit vault recovery:
enumerate Journal-owned zones in the private database, accepted shared zones in
the shared database, materialize any missing catalog rows, and then hand record
imports back to the normal sync path. If recovery finds no local or remote
vaults, the runtime treats the install as a new-user state and leaves the vault
picker empty until the user creates a vault.
Live CloudKit account/network behavior, including two-account invite
acceptance, still needs device or signed simulator verification.

**Before sync works on real devices:** create/let Xcode auto-create the
`iCloud.app.muukii.journal` container, verify the vault record types in the
CloudKit Console during Development, test private and shared vaults on two
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
