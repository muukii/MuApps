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

- A working **SwiftData + CloudKit persistence stack** (the `Card` / `Tag` /
  `Attachment` / `CardRelationship` model graph, verified to initialize and
  pass CloudKit schema validation).
- Six **capture components**, each built as an isolated framework so it can be
  developed and exercised on its own, independent of the undecided UI.
- A **compose-first app shell** (`CreationView`) that writes text, photo, audio,
  and doodle Cards through card-specific detail editors, plus a **dev gallery**
  (`CaptureGalleryView`) that launches each component standalone for on-device
  testing. The dev gallery is scaffolding, **not the shipping entry point**.
- A **theming system** (`MuColor`) and a **Core Haptics lab** (`MuHaptics`).
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
`Shared/`) because they are app-scoped, not cross-app.

```
Journal (app, app.muukii.journal)
├── JournalWidget      — WidgetKit extension (app.muukii.journal.JournalWidget)
│   └── JournalModel    (reads the shared store)
├── JournalModel       — data layer: Card/Tag/Attachment/CardRelationship/Coordinate
│                        + JournalStore
│                        (dynamic framework, linked by both app and widget)
├── MuColor            — color themes / palette + container views
├── MuHaptics          — Core Haptics pattern editor & engine (Lab)
├── CaptureText        — text note capture
├── CapturePhoto       — camera capture (depends on Capturer)
├── CaptureDoodle      — SwiftUI vector ink canvas (depends on CoreHaptics)
├── CaptureBlob        — translucent gradient shape painting (no extra deps)
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
descending, `fetchLimit = 1`) and shows kind-aware display text: text cards use
`Card.body` (falling back to `title`), while media cards show a modality label.
It maps the `Card` to a `Sendable` `NoteSnapshot` so the timeline entry and
views stay free of the persistence layer, and shows an empty state when there
are no notes.

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
`AudioRecording`, `DoodleDrawing`) so editors can reopen and continue those
values. `ThreadDraftCard` is `Codable` for crash recovery, and only encodes the
draft payload; SwiftUI presentation identity is rebuilt after restore.
Immediately before saving, the composer snapshots each draft and converts it into
`ThreadCardInput`. Text inputs write into `Card.body`; photo and doodle inputs
stage encoded bytes plus thumbnails; audio inputs move the recording file URL
into the shared media directory as an `.audio` attachment. The thread write still
performs one final `ModelContext.save()`;
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
| `kind` | `Kind` | Primary modality: `.text`, `.photo`, `.audio`, or `.doodle`. Determines which content field/attachment is meaningful. |
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
cards expect a matching `Attachment.kind` (`.photo`, `.audio`, or `.doodle`) and
do not render `body` as a caption.

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

Attachments represent photos, audio recordings, and doodles associated with a
card. The SwiftData row stores queryable metadata and a small thumbnail; the full
bytes live as files in the App Group container and are reconciled by
`JournalStore.reconcileOrphanFiles(...)`.

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Logical id and file name basis. |
| `kind` | `Kind` | `.photo`, `.audio`, or `.doodle`. |
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
front/back flip) built on the **Capturer** library. Handles authorization states
(`unknown` / `authorized` / `denied` / `unavailable`) and emits the still through
`onCapture`.

- `CapturedPhoto`: `Sendable, Equatable` — `imageData: Data` (JPEG bytes),
  `pixelSize: CGSize`, lazy `image: UIImage?`,
  `thumbnailData(maxPixelLength:)` for generating a small preview JPEG.
- `CameraController` drives Capturer's async camera API; `CameraPreviewView`
  mounts Capturer's `PixelBufferView` in SwiftUI.

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
Default smoothing strength is `0.99`. While drawing, supported devices play a
Core Haptics continuous texture whose intensity and sharpness follow finger
speed; unsupported hardware, including Simulator, no-ops. The drawable surface
is fixed to the same portrait paper proportion as journal cards
(`width / height = 1 / 1.4144`), and the toolbar is single-color: width slider,
undo, replay, clear, and export when `onExport` is supplied. When `onChange` is
supplied, the canvas emits the current `DoodleDrawing?` after committed stroke
changes, undo, or clear so hosts can auto-save drafts.

- `DoodleDrawing`: `Sendable, Equatable, Codable` — `strokes: [DoodleStroke]`,
  `canvasSize: CGSize`, `duration: TimeInterval`. `image(inkColor:scale:)`
  rasterizes a tinted thumbnail on demand.
- `DoodleStroke`: `points: [DoodlePoint]` (each `x, y, time`, optional
  point-level `width`), `width: Double` base brush width.
- Supporting types: `DoodleCanvas` (controller), `DoodleStrokesView` (renderer),
  `InkSmoothing`, `StrokeSmoothing` (streamline and legacy algorithms),
  `DoodleDrawingHaptics`, `DrawingGestureRecognizer` (timestamped),
  `TimedPoint`.

### CaptureBlob → `BlobPainting`

`BlobPaintCanvasView(onExport:)` — a separate **SwiftUI vector** surface for
translucent filled shapes, not ink strokes. Each finger stroke creates one
closed ribbon-like `BlobLayer`: a smoothed centerline, a large fixed layer width,
and an owned gradient style. The live layer is the authored layer; lifting the
finger commits the visible shape as-is without a second fitting pass. Layers are
drawn in order with translucent linear gradients, giving overlap and depth
similar to abstract gradient paper cutouts. The toolbar offers gradient swatches,
width slider, undo, clear, and export.

- `BlobPainting`: `Sendable, Equatable, Codable` — `layers: [BlobLayer]`,
  `canvasSize: CGSize`, `duration: TimeInterval`. `image(scale:)` rasterizes a
  thumbnail on demand.
- `BlobLayer`: `id`, `points: [BlobPoint]` (centerline `x, y, time`),
  `width: Double`, `style: BlobGradientStyle`.
- Supporting types: `BlobPaintCanvas` (controller), `BlobPaintingRenderer`,
  `BlobGradientStyle`, `BlobColor`, and the component-local touch recognizer.

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
  and applies its palette. It is also the first-run gate: while
  `@AppStorage(JournalDefaults.hasCompletedOnboarding)` is `false` it hosts
  `OnboardingView`; once completed it cross-fades (`.transition(.opacity)`) to
  `CreationView`. The completion flag is flipped by the closure `RootView` passes
  to `OnboardingView`, not by the onboarding view itself.
- **`OnboardingView`** — the first-run introduction, also re-showable on demand
  from Settings. Four horizontally-paged screens (`TabView` with
  `.tabViewStyle(.page)`) plus a fixed **Get Started** / **Next** call-to-action
  and a **Skip** affordance on every page but the last:
  1. **Welcome** — a decorative `CardSurface` stating the core idea ("Every little
     thing becomes a card") over a short welcome blurb.
  2. **Capture methods** — the six modalities (Text, Photo, Doodle, Blob Paint,
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
- **`CreationView`** (current app root) — the compose screen: a date header
  (`DateView`) showing today's weekday, month, and day, then
  a vertical `ScrollView` of card-shaped draft summaries. The header is rendered
  with the standard `Date.FormatStyle` field selection, so its field order and
  separators follow the user's locale (en: "Sat, Jun 27"; ja: "6月27日(土)").
  Each draft Card shows its ordinal, kind chip, optional location indicator, and
  a kind-aware summary: text previews the trimmed body or "Write your thoughts…";
  photo and doodle show the captured thumbnail or an "Open camera/canvas" prompt;
  audio shows the recorded duration or an "Open recorder" prompt. Tapping a
  non-audio card opens `ThreadDraftCardDetailEditor` in a `fullScreenCover` with
  a zoom transition from the card surface, a segmented kind picker, and one
  concrete editor per kind. Tapping an audio card opens a native **Voice Record**
  sheet instead, showing **Play** and **Record Again** for an existing
  `AudioRecording` or `AudioCaptureView` for a new take. The bottom composer
  controls include **Voice Record**, which opens the same sheet without creating a
  draft until recording finishes; the first untouched text placeholder is reused
  for the completed audio card, otherwise a new audio draft is appended. Text
  reopens the existing draft body in a `TextEditor`; photo reopens the existing
  `CapturedPhoto` with a **Retake Photo** action that switches back to
  `PhotoCaptureView`; doodle reopens the existing `DoodleDrawing` in
  `DoodleCanvasView` so new strokes append to the same vector drawing. The editor
  toolbar owns the `Done` dismissal action and the per-card location toggle. The
  doodle editor auto-syncs committed canvas changes into the draft; there is no
  separate save button for doodles. **Add Card**
  appends another draft, scrolls it into view, and opens the same full-screen
  editor. The glass up-arrow saves the current draft cards as a linear
  thread via `JournalStore.createThread(cards:in:)`, then clears the composer.
  The save button is disabled until every draft can be persisted (text requires
  non-empty trimmed text; media kinds require a captured payload). Existing-Card
  continuation selection is not wired yet; this composer creates a new thread
  from the first draft.
  Toolbar links to the entries list (`ListView`) and Settings. Capture demos are
  still reachable from Settings; blob paint and suggestions remain dev-gallery
  components rather than compose-surface card kinds.
- **`CaptureGalleryView`** (dev scaffolding, not currently wired into the app
  root) — a `List` with:
  - **Capture**: Text, Photo, Doodle, Blob Paint, Ambient Sound, Suggestions.
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
  (1 : 1.4144), filled with the active palette's `secondaryContainer`. Each tile
  renders exactly one card pattern based on `Card.kind`: text (`Card.body`),
  audio (waveform chrome), image (the matching photo attachment thumbnail), or
  doodle (the matching doodle thumbnail). Media cards do not render `Card.body`
  as a caption; a captured
  audio/image/doodle is its own Card. Each tile is tilted by a small stable angle
  (±3°) derived from its `Card.id`, for a loosely hand-placed look. The debug
  **Seed Samples** action and `Card Patterns` Preview exercise those four
  independent patterns. Not the real entries UI.
- **`SettingsView`** — a theme picker plus a development capture list. Selecting
  a theme writes `JournalDefaults.themeID` (animated) and triggers selection
  haptic feedback. The capture list links to Text, Photo, Doodle, Blob Paint,
  Ambient Sound, Suggestions, and the Haptics lab so those components can be
  tried from the current app root. An **About** section has **Show Onboarding**,
  which re-presents `OnboardingView` in a `fullScreenCover`; dismissing it returns
  to the app without changing `hasCompletedOnboarding`.

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
`CaptureDoodle`, `CaptureBlob`, `CaptureAudio`, `CaptureSuggestions`, `MuColor`,
`MuHaptics`) for building/running it in isolation.

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
