# Journal — Specification

The current, factual state of the `Journal` app. Update this whenever a
functional change lands (see [Documentation Policy](#documentation-policy)).

---

## Overview

`Journal` is a journaling app for iPhone and iPad. Each thing a user records —
text, a photo, a doodle, Bauhaus grid artwork, ambient sound, a Journaling
Suggestion — becomes one **Card**. iCloud sync across a user's devices is a hard
product requirement, so persistence is **SwiftData with CloudKit mirroring**.

### Project status

The app is **pre-product**: the real journaling UI is still being designed. What
exists today is:

- A working **SwiftData + CloudKit persistence stack** (the `Card` / `Tag` /
  `Attachment` / `CardRelationship` model graph, verified to initialize and
  pass CloudKit schema validation).
- Six **capture components**, each built as an isolated framework so it can be
  developed and exercised on its own, independent of the undecided UI.
- A **compose-first app shell** (`CreationView`) that writes text, photo, audio,
  doodle, and Bauhaus Cards through card-specific editors, plus a **dev gallery**
  (`CaptureGalleryView`) that launches each component standalone for on-device
  testing. The dev gallery is scaffolding, **not the shipping entry point**.
- A **theming system** (`MuColor`) and **Core Haptics labs** (`MuHaptics`).
- A **widget-ready structure**: the data layer lives in a shared `JournalModel`
  framework and the SwiftData store is in an App Group container, so the
  `JournalWidget` extension reads the same Cards as the app. A minimal "Recent
  Cards" widget ships as a scaffold proving the structure works end-to-end.

Because the product shell is undecided, capture components are deliberately
**persistence-agnostic**: each emits a plain `Sendable` value through a
`@MainActor @Sendable` callback and knows nothing about `Card`, SwiftData, or
iCloud. The app shell converts those values into `ThreadDraftCard` payloads
before persistence sees them.

---

## Architecture

Tuist project (`Apps/Journal/Project.swift`) with an app target, a **widget
extension**, a shared **data-layer framework**, and several **Journal-local
static frameworks**. The frameworks live inside the app (not in the repo's
`Shared/`) because they are app-scoped, not cross-app. All Journal target source
roots are grouped under `Apps/Journal/Sources/<TargetName>/`; the app icon
package is `Apps/Journal/Sources/Journal/Icon.icon`. The target and module names
remain `Journal`; the user-facing bundle display name is `Tinycurve`.

```
Journal (app, app.muukii.journal)
├── JournalWidget      — WidgetKit extension (app.muukii.journal.JournalWidget)
│   └── JournalModel    (reads the shared store)
├── JournalModel       — data layer: Card/Tag/Attachment/CardRelationship/Coordinate
│                        + JournalStore
│                        (dynamic framework, linked by both app and widget)
├── MuColor            — color themes / palette + container views
├── MuHaptics          — Core Haptics pattern editor, tap sequencer & engine (Lab)
├── CaptureText        — text note capture
├── CapturePhoto       — camera capture (AVFoundation)
├── CaptureDoodle      — SwiftUI vector ink canvas (depends on CoreHaptics)
├── CaptureBauhaus     — 5 x 5 Bauhaus-style grid composer
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
explicit target dependency) is a WidgetKit extension. Its single **Latest Note**
widget (small / medium / large families) reads the single most recently created
`Card` directly from the shared SwiftData store via
`JournalStore.makeModelContainer()` (a `FetchDescriptor` sorted by `createdAt`
descending, `fetchLimit = 1`) and shows kind-aware content: text cards use
`Card.body` (falling back to `title`), doodle and Bauhaus cards render matching
attachment thumbnails, and the other media cards still show a modality label.
It maps the `Card` to a `Sendable` `NoteSnapshot` so the timeline entry and
views stay free of the persistence layer, capture frameworks, and media files;
it shows an empty state when there are no notes.

The widget refreshes whenever a note is written: `CreationView.save()` calls
`WidgetCenter.shared.reloadAllTimelines()` after `JournalStore.createThread(...)`
succeeds. WidgetKit also re-runs the timeline periodically to keep the relative
date current.

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
`ModelContainer` for journal data anywhere else. The schema is `Card.self`,
`Tag.self`, `Attachment.self`, and `CardRelationship.self`.

`JournalStore` also owns the **write path**:
`createCard(body:location:continuingFrom:in:)` builds a `Card` from captured
text, optionally stores where it was written, optionally connects it to a
previous Card as a `.continuation`, inserts everything into the given
`ModelContext`, and saves immediately (explicitly, not via SwiftData autosave, so
the caller can react to a failure). Card creation funnels through here rather
than scattered `context.insert(Card(...))` calls.
`createThread(cards:continuingFrom:in:)` accepts `JournalStore.ThreadCardInput`
values and saves them as one linear thread write, connecting each Card to the
previous one with `.continuation`. The app-side `ThreadDraftCard` keeps
composer media in the capture components' own value types (`CapturedPhoto`,
`AudioRecording`, `DoodleDrawing`, `BauhausGridArtwork`) so editors can reopen
and continue those values. `ThreadDraftCard` is `Codable` for crash recovery,
and only encodes the draft payload; SwiftUI presentation identity is rebuilt
after restore.
Immediately before saving, the composer snapshots each draft and converts it into
`ThreadCardInput`. Text inputs write into `Card.body`; photo, doodle, and
Bauhaus inputs stage encoded bytes plus thumbnails; audio inputs move the
recording file URL into the shared media directory as an `.audio` attachment.
The thread write still performs one final `ModelContext.save()`;
attachment files are written or moved before that save, with orphan cleanup
handled by `reconcileOrphanFiles(...)`.
`createRelationship(from:to:kind:in:)` connects existing Cards and enforces the
app-level DAG rule: no self-edge and no edge that would create a cycle. It is
idempotent for the same source / target / kind triplet because CloudKit
mirroring cannot enforce uniqueness.

All models obey **CloudKit-mirroring constraints**: every stored property is
optional or has a default, no `.unique` attributes, and every relationship is
optional. A consequence is that uniqueness cannot be enforced — the same logical
record created on two devices can produce duplicate rows; de-duplication, if it
ever matters, is an app-level concern.

### `Card` — a single post

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Logical id; not unique-enforced (see above). |
| `kind` | `Kind` | Primary modality: `.text`, `.photo`, `.audio`, `.doodle`, or `.bauhaus`. Determines which content field/attachment is meaningful. |
| `createdAt` | `Date` | |
| `updatedAt` | `Date` | |
| `tags` | `[Tag]?` | Many-to-many; inverse declared on `Tag.cards`. |
| `attachments` | `[Attachment]?` | Media metadata rows owned by the card; bytes live outside SwiftData. |
| `outgoingRelationships` | `[CardRelationship]?` | Directed edges that start from this card. |
| `incomingRelationships` | `[CardRelationship]?` | Directed edges that point at this card. |
| `location` | `Coordinate?` | `nil` = no location (not permitted or unavailable). |
| `title` | `String` | |
| `body` | `String` | |

`kind` is the canonical content contract. `.text` cards render `body`; media
cards expect a matching `Attachment.kind` (`.photo`, `.audio`, `.doodle`, or
`.bauhaus`) and do not render `body` as a caption. Bauhaus cards use `.bauhaus`
attachments with encoded `BauhausGridArtwork` JSON plus a mirrored thumbnail.

### `Tag` — a label applied to many Cards

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | |
| `name` | `String` | |
| `createdAt` | `Date` | |
| `cards` | `[Card]?` | `@Relationship(inverse: \Card.tags)`. Declared on this side only. |

### `CardRelationship` — a directed edge between Cards

`CardRelationship` is stored as its own model so Card-to-Card links are a graph,
not a single-parent tree. A thread is a path through this graph; replies and
references can branch from any earlier card. The app-level invariant is DAG:
`JournalStore.createRelationship(...)` rejects self-links and cycles.

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Logical id; not unique-enforced. |
| `kind` | `Kind` | `.continuation`, `.reply`, or `.reference`. |
| `createdAt` | `Date` | Timestamp for the edge itself. |
| `sortIndex` | `Int` | Stable order among same-kind outgoing relationships from a source card. |
| `source` | `Card?` | Start of the directed edge. |
| `target` | `Card?` | Destination of the directed edge. |

### `Attachment` — media metadata for a Card

Attachments represent photos, audio recordings, doodles, and Bauhaus artwork
associated with a card. The SwiftData row stores queryable metadata and a small
thumbnail; the full bytes live as files in the App Group container and are
reconciled by `JournalStore.reconcileOrphanFiles(...)`.

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Logical id and file name basis. |
| `kind` | `Kind` | `.photo`, `.audio`, `.doodle`, or `.bauhaus`. |
| `byteSize` | `Int` | Size of the on-disk file at attach time. |
| `thumbnail` | `Data?` | Small mirrored preview data, when generated. |
| `createdAt` | `Date` | |
| `card` | `Card?` | Owning card; inverse declared on `Card.attachments`. |

### `Coordinate` — a geographic point

A `Codable, Hashable, Sendable` struct (`latitude`, `longitude`) stored on `Card`
as an optional SwiftData composite attribute. Bridges to/from
`CLLocationCoordinate2D`. A present value always implies the user permitted
location use.

Location capture is wired into `CreationView` as a per-card opt-in from the
detail editor toolbar. Tapping the location button prompts for When-In-Use access
when needed, requests a one-shot coordinate immediately, and stores the resolved
`Coordinate` on that draft. Saving uses the coordinate already attached to each
draft, and still saves the card without a location when access is denied or no
fix is available.

---

## Capture Components

Each is an isolated framework that emits a value type through a callback and owns
no persistence. The dev gallery hosts each in a standalone demo view; the
compose detail editors also host Photo, Doodle, and Ambient Sound and convert
their callbacks into `ThreadDraftCard` payloads. Text composition currently uses
an app-shell `TextEditor` bound directly to `ThreadDraftCard.text`.

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
  `pixelSize: CGSize`, lazy `image: UIImage?`,
  `thumbnailData(maxPixelLength:)` for generating a small preview JPEG.
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
same emitted timeline: each point stores an optional rendered width, fast spans
thin out, stroke tips taper lightly, and the renderer draws dense overlapping
round segments so tapering doesn't fold into a broken outline at tight turns.
Default brush width is `3pt`. While drawing, supported devices bracket each
stroke with light touch-down/lift taps and keep the in-stroke Core Haptics
continuous texture light while its intensity and sharpness follow finger speed;
unsupported hardware, including Simulator, no-ops. The drawable
surface is fixed to the same portrait paper proportion as journal cards
(`width / height = 1 / 1.4144`), and the toolbar is single-color: width slider,
undo, replay, clear, and export when `onExport` is supplied. When `onChange` is
supplied, the canvas emits the current
`DoodleDrawing?` after committed stroke changes, undo, or clear so hosts can
auto-save drafts.

- `DoodleDrawing`: `Sendable, Equatable, Codable` — `strokes: [DoodleStroke]`,
  `canvasSize: CGSize`, `duration: TimeInterval`. `image(inkColor:scale:)`
  rasterizes a tinted thumbnail on demand.
- `DoodleStroke`: `points: [DoodlePoint]` (each `x, y, time`, optional
  point-level `width`), `width: Double` base brush width.
- Supporting types: `DoodleCanvas` (controller), `DoodleStrokesView` (renderer),
  `StrokeSmoothing` (fixed streamline pipeline), `DoodleDrawingHaptics`,
  `DrawingGestureRecognizer` (timestamped), `TimedPoint`.

### CaptureBauhaus → `BauhausGridArtwork`

`BauhausGridCaptureView(initialArtwork:onChange:onExport:)` — a SwiftUI grid
composer for Bauhaus-style geometric artwork. The canvas is a fixed **5 x 5**
grid of square cells. Tapping a cell presents a native shape picker sheet; the
user chooses one of the prepared primitives (square, circle, four semicircles,
four quarter-circles, and four diagonal triangles), and the selected
shape/background colors are applied to that cell. Compact swatch rows choose the
active primitive and cell background colors, the trash action clears the whole
artwork, and an optional export callback lets hosts finish the capture
explicitly. Every cell edit and clear emits the current `BauhausGridArtwork`
through `onChange`.

- `BauhausGridArtwork`: `Sendable, Equatable, Codable` — row-major 25-cell
  storage where each cell is either empty or a `BauhausTile`.
- `BauhausGridPosition`: `Sendable, Equatable, Hashable, Codable, Identifiable`
  — a stable zero-based row/column coordinate inside the 5 x 5 grid.
- `BauhausTile`: `Sendable, Equatable, Codable` — `shape: BauhausShapeKind`,
  `shapeSwatch: BauhausSwatch`, `backgroundSwatch: BauhausSwatch`.
- `BauhausShapeKind`: prepared geometric primitives that each fit inside one
  square cell.
- `BauhausSwatch`: a fixed Codable content-color token set. These are authored
  artwork colors, not app theme colors.

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
  the seeds. Colors are Display P3, declared via the `#hexColor` macro (the
  external `HexColorMacro` dependency).
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

- **`JournalApp`** (`@main`) — builds the `ModelContainer` for the `Card` + `Tag`
  schema with `ModelConfiguration(cloudKitDatabase: .automatic)`, and injects the
  persisted theme palette via `RootView` → `PrimaryContainer`.
- **`RootView`** — reads the persisted theme (`@AppStorage(JournalDefaults.themeID)`)
  and applies its palette. It is also the first-run gate: while
  `@AppStorage(JournalDefaults.hasCompletedOnboarding)` is `false` it hosts
  `OnboardingView`; once completed it cross-fades (`.transition(.opacity)`) to
  `CreationView`. The completion flag is flipped by the closure `RootView` passes
  to `OnboardingView`, not by the onboarding view itself. It also owns the
  scene-local `JournalNotificationCenter` and wraps the app content in
  `JournalNotificationHost`, which injects that model through the SwiftUI
  environment and overlays app-wide bottom capsule notifications above the
  current screen.
- **`OnboardingView`** — the first-run introduction, also re-showable on demand
  from Settings. Four horizontally-paged screens (`TabView` with
  `.tabViewStyle(.page)`) plus a fixed **Get Started** / **Next** call-to-action
  and a **Skip** affordance on every page but the last:
  1. **Welcome** — a decorative `CardSurface` stating the core idea ("Every little
     thing becomes a card") over a short welcome blurb.
  2. **Capture methods** — the five modalities (Text, Photo, Doodle, Ambient
     Sound, Suggestions) as icon + name + one-line summary.
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
- **`CreationView`** (current app root) — the compose screen: a date header
  (`DateView`) showing today's weekday, month, and day, then
  a vertical `ScrollView` of card-shaped draft summaries. The header is rendered
  with the standard `Date.FormatStyle` field selection, so its field order and
  separators follow the user's locale (en: "Sat, Jun 27"; ja: "6月27日(土)").
  Each draft Card shows its ordinal, kind chip, optional location indicator, and
  a kind-aware summary: text previews the trimmed body or "Write your thoughts…";
  photo, doodle, and Bauhaus show the captured thumbnail or an "Open
  camera/canvas/grid" prompt; audio shows the recorded duration or an "Open
  recorder" prompt. Tapping a text card opens a native **Text** sheet with a
  focused `TextEditor` and the per-card location toggle in the toolbar. Tapping a
  photo card opens a native **Photo** sheet, showing the existing
  `CapturedPhoto` with **Retake Photo** or `PhotoCaptureView` for a new shot.
  Tapping a doodle card opens a dedicated full-screen **Doodle** canvas that
  reopens the existing `DoodleDrawing` in `DoodleCanvasView` so new strokes append
  to the same vector drawing. Tapping a Bauhaus card opens a native **Bauhaus**
  sheet that restores the existing `BauhausGridArtwork`; tapping a cell presents
  the shape picker sheet, and choosing a shape applies it into the selected 5 x 5
  grid cell. Tapping an audio card opens a native **Voice Record** sheet, showing
  **Play** and **Record Again** for an existing
  `AudioRecording` or `AudioCaptureView` for a new take. The bottom composer
  controls put the concrete content-type icons — Text, Photo, Doodle, Bauhaus,
  and Voice — in separated Liquid Glass buttons inside one shared
  `GlassEffectContainer`, with the save action remaining a separate prominent
  glass button. Tapping one of those quick-capture icons presents the matching
  native sheet. Text opens the last untouched text placeholder when one exists;
  otherwise it creates a new text draft and opens the Text sheet. Photo and Voice
  create/reuse a draft only after capture finishes, then dismiss back to the
  composer. Doodle and Bauhaus present native sheets at the large detent and
  resolve a draft on the first non-empty canvas/grid change, reusing the first
  untouched text placeholder when possible and restoring/removing that quick draft
  if the canvas/grid is cleared. The doodle canvas and Bauhaus grid auto-sync
  committed changes into the draft; there is no separate save button for those
  visual editors. The glass up-arrow saves the current draft cards as a linear
  thread via `JournalStore.createThread(cards:in:)`, then clears the composer.
  A successful save shows a transient bottom capsule notification ("Saved to
  Journal") with success haptics; if saving fails, the draft remains on screen
  and a persistent bottom capsule notification explains that the save did not
  complete with failure haptics. Notifications fade, blur, and scale in place
  with a slight bounce instead of sliding from an edge.
  The save button is disabled until every draft can be persisted (text requires
  non-empty trimmed text; media kinds require a captured payload). Existing-Card
  continuation selection is not wired yet; this composer creates a new thread
  from the first draft.
  Toolbar links to the entries list (`ListView`) and Settings. Capture demos are
  kept in the dev gallery rather than Settings; suggestions remain a dev-gallery
  component rather than a compose-surface card kind.
- **`CaptureGalleryView`** (dev scaffolding, not currently wired into the app
  root) — a `List` with:
  - **Capture**: Text, Photo, Doodle, Bauhaus Grid, Ambient Sound, Suggestions.
  - **Lab**: Haptics, Haptic Doodle in Debug builds only.
  - **Storage**: Entries (SwiftData / iCloud) → `ListView`.
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
- **`ListView`** — a `@Query`-backed entries harness over `Card` that exists only
  to exercise the SwiftData + CloudKit stack end-to-end. Cards are grouped into
  local-calendar day sections, each with a localized date header and a responsive
  `LazyVGrid` of portrait tiles shaped like a sheet of paper (1 : 1.4144), filled
  with the active palette's `secondaryContainer`: compact widths keep two
  columns, while regular-width iPad layouts add columns as space allows. Each tile
  renders exactly one card pattern based on `Card.kind`: text (`Card.body`),
  audio (waveform chrome), image (the matching photo attachment thumbnail),
  doodle (the matching doodle thumbnail), or Bauhaus (the matching grid
  thumbnail). Media cards do not render `Card.body` as a caption; a captured
  audio/image/doodle/Bauhaus grid is its own Card. Each tile is tilted by a small
  stable angle (±3°) derived from its `Card.id`, for a loosely hand-placed look.
  Tapping a tile pushes an **Entry** detail screen. The detail screen uses a
  separate, non-tilted, variable-height card component so it can show full text,
  a larger photo/doodle/Bauhaus preview, audio playback when the local recording
  file exists, and created/updated/location metadata without inheriting the grid
  tile's clipping and aspect-ratio limits. Each tile's context menu and the detail toolbar
  include **Share**, which opens a pre-share preview sheet before any system
  share sheet is shown. The preview displays the themed image export; it lays out
  the actual 9:16 export canvas and aspect-fits that result into the sheet instead
  of reflowing the card at preview size. Doodle cards also get a **Video** tab
  that replays the stored vector timeline in the same share chrome. **Share
  Image** renders that Card into a themed 9:16 PNG sized for Instagram Reels;
  **Share Video** renders a matching 9:16, 60 fps Doodle replay mp4 by reusing a
  static SwiftUI-rendered share frame and compositing only the moving vector
  strokes, then presents it through the system share sheet. Bauhaus cards share
  as still images using their mirrored grid thumbnail. The debug **Seed Samples**
  action and `Card Patterns` Preview exercise the independent card patterns.
  Not the real entries UI.
- **`SettingsView`** — an iCloud sync status row, a theme picker, optional
  Debug-only Lab links, and About actions. Selecting a theme writes
  `JournalDefaults.themeID` (animated) and triggers selection haptic feedback.
  Capture demos are intentionally hidden from Settings. In Debug builds, **Lab**
  links to Haptics and Haptic Doodle so those tools can be tried from the current
  app root; Release builds omit the Lab section. An **About** section has **Show
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
