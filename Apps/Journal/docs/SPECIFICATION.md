# Journal — Specification

The current, factual state of the `Journal` app. Update this whenever a
functional change lands (see [Documentation Policy](#documentation-policy)).

---

## Overview

`Journal` is a journaling app for iPhone, iPad, and native macOS. Each thing a
user records — text, a shared file, a photo, a doodle, Bauhaus grid artwork, ambient sound, or
(on supported iPhone/iPad hardware) a Journaling Suggestion — becomes one
**Card**. iCloud sync and vault collaboration are hard product requirements, so
the app is moving to **per-vault SwiftData stores with CloudKit mirroring
disabled** and explicit CloudKit sync through `JournalVault`.

### Project status

The app is **pre-product**: the real journaling UI is still being designed. What
exists today is:

- A working **JournalVault persistence foundation**: a catalog store, per-vault
  content stores, `CardEdge` / `Card` / `Attachment` rows, outbox mutations, and
  an explicit CloudKit sync boundary.
- Six **capture components**, each built as an isolated framework so it can be
  developed and exercised on its own, independent of the undecided UI.
- A **Creation-first app shell** that automatically activates the restored or
  first available vault, presents `VaultSelectionView` as a management sheet,
  then writes text, link, photo, audio, doodle, and
  Bauhaus Cards into the selected `VaultInstance` through card-specific editors,
  plus a **dev gallery**
  (`CaptureGalleryView`) that launches each component standalone for on-device
  testing. The dev gallery is scaffolding, **not the shipping entry point**.
- A **theming system** (`MuColor`) and **Core Haptics labs** (`MuHaptics`).
- A **vault-selectable widget**: `JournalWidget` lets each widget instance choose
  one vault and reads the latest card from that vault's App Group store.
- **System capture entry points**: a configurable Control for Action Button /
  Control Center, App Shortcuts and a background text-posting intent, an explicit
  Quick Capture Vault, and an iOS Share Extension for text, links, photos, videos,
  and files. Locked Camera Capture is intentionally not part of this feature.

Because the product shell is undecided, capture components are deliberately
**persistence-agnostic**: each emits a plain `Sendable` value through a
`@MainActor @Sendable` callback and knows nothing about `Card`, SwiftData, or
iCloud. The app shell converts those values into `CardEditDraft` payloads
before persistence sees them.

---

## Architecture

Tuist project `Tinycurve` (`Apps/Journal/Project.swift`) with a `Tinycurve` app
target, **widget**,
**App Intents**, and **Share** extensions, the vault **data-layer framework**,
an extension-safe `JournalIntents` framework, and several **Journal-local static
frameworks**. The frameworks live inside the app (not in the repo's
`Shared/`) because they are app-scoped, not cross-app. All Journal target source
roots are grouped under `Apps/Journal/Sources/<TargetName>/`; the app icon
package is `Apps/Journal/Sources/Journal/Icon.icon`. The project, app target,
scheme, executable, module, and user-facing bundle display name are `Tinycurve`;
the WidgetKit extension bundle display name is `Tinycurve Widget`.
The same app, framework, test, and widget targets compile natively for iPhone,
iPad, and macOS. The Mac product keeps bundle id `app.muukii.journal`, CloudKit
container, and App Group identity aligned with iOS. Native macOS app and widget
Debug builds use an Apple Development identity because
CloudKit and App Group entitlements cannot run under ad-hoc local signing.
The native Mac app runs in App Sandbox with outgoing network, user-selected
read-only files, camera, microphone, location, and Photos access enabled; each
privacy-sensitive feature still requests runtime authorization before use.

```
Tinycurve (app, app.muukii.journal)
├── JournalWidget      — WidgetKit extension (app.muukii.journal.JournalWidget)
│   ├── JournalVault    (vault catalog/content reader)
│   ├── CaptureDoodle   (read-only widget renderer)
│   └── CaptureBauhaus  (read-only widget renderer)
├── JournalAppIntentsExtension — background text posting + App Shortcuts
├── JournalShareExtension      — iOS system Share sheet entry point
├── JournalIntents     — shared entities, preferences, routing, posting service
├── CloudKitSupport    — macro-generated CKRecord transport wrappers
├── JournalVault       — vault catalog/content stores + explicit CloudKit sync
├── MuColor            — color themes / palette + container views
├── MuHaptics          — Core Haptics pattern editor, tap sequencer & engine (Lab)
├── CaptureText        — text note capture
├── CapturePhoto       — camera capture (AVFoundation)
├── MediaProcessing    — save-time media derivatives (Image I/O thumbnails)
├── CaptureDoodle      — SwiftUI vector ink canvas (depends on CoreHaptics)
├── CaptureBauhaus     — 5 x 5 Bauhaus-style grid composer
├── CaptureAudio       — ambient sound recording (depends on AVFoundation)
└── CaptureSuggestions — Apple Journaling Suggestions picker demo
```

`JournalVault` is the app shell's active persistence framework and the widget's
vault reader. It depends on the local Swift package `CloudKitSupport` for
macro-generated, class-based wrappers that own `CKRecord` instances directly.
Those wrappers are CloudKit transport objects only: they stay inside the sync
boundary and are translated to/from SwiftData-backed domain rows before data
reaches app UI. The legacy `JournalModel` module has been removed; product
migration code is not kept in the app while Journal is still pre-release.

### Localization

The app target includes localized resources under
`Apps/Journal/Resources/Journal/`. `Localizable.xcstrings` covers the current
English and Japanese product-facing app shell: onboarding, composer actions,
vault selection, saved entries, settings, widget instructions, privacy policy,
and capture permission/capture surfaces. The app target also ships
`InfoPlist.xcstrings` so iOS permission dialogs show localized camera, Photos,
microphone, and location usage descriptions.

The widget extension has its own bundle resources under
`Apps/Journal/Resources/JournalWidget/` because WidgetKit and App Intents resolve
their display names, descriptions, configuration labels, empty states, and
content fallback labels from the extension bundle rather than from the app
bundle.

### Fresh schema startup

`TinycurveApp` creates `JournalVaultRuntime` on launch. The runtime starts the
sync layer and leaves the catalog empty when CloudKit recovery finds no owned or
accepted shared vaults. That empty catalog is the new-user state; the app does
not create preset vaults at install time and does not open the old App Group
SwiftData SQLite store.

The App Group vault tree is scoped by the active CloudKit server environment:
Debug builds read and write `Journal/development`, while Release, TestFlight,
and App Store builds read and write `Journal/production`. Each environment owns
its own catalog, per-vault stores, media files, and CKSyncEngine state so
development records, production records, change tokens, and archived
`CKRecord` system fields do not cross environments.

Because the app has not shipped with user data, Journal does not keep product
migration APIs or legacy import DTOs. Schema changes can replace the pre-release
store shape directly; developer-only recovery can be built outside the app if it
is ever needed.

If the app-lifetime runtime cannot open a pre-release vault content store after a schema break,
`VaultContentStore.open` discards that vault's local `store.sqlite*` files and
`media/` directory, then recreates the store. It also clears CKSyncEngine state
and asks the sync engine to refetch, so CloudKit records and CKAssets can
materialize the fresh store. The reset does not remove the catalog row or sibling
vault content stores.
Extension processes use `.failWithoutReset` instead, so a transient concurrent
open cannot delete shared data from a short-lived process.

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
`Card.body` (falling back to `Untitled`), link cards use their stored URL string,
photo cards use the save-time raster thumbnail stored on their attachment, file
cards show their original name and type/size metadata, and
doodle / Bauhaus cards decode their authored JSON attachment and render
`DoodleDrawingView` / `BauhausGridArtworkView`. Audio cards still show a typed
modality label because there is not yet a visual authored renderer for audio.
The Home Screen families show the selected vault title, latest-card body,
rendered visual media, or audio label plus the relative timestamp; the Lock
Screen accessory families use short labels or symbols that fit the tighter
surfaces. Native macOS exposes the small / medium / large families; the Lock
Screen accessory families remain iOS-only because WidgetKit does not make them
available on macOS.
It maps the `Card` to a `Sendable` `NoteSnapshot` so the timeline entry and
views stay free of live SwiftData model references; it shows an empty state when
there are no vaults or when the chosen vault has no cards.

New card saves and saved-card edits request
`WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)` so
configured widgets refresh promptly. The 15-minute periodic timeline refresh
remains only for relative-date freshness. Future optimization can denormalize
latest-card previews into `VaultSummary`, but current product behavior reads the
selected vault store directly.

### System capture extensions

`JournalWidget` also contributes a configurable **Quick Capture** Control. It is
available to Control Center, Lock Screen controls, and the iPhone Action Button;
each placement can select a writable Vault and Text, Photo, Voice, Doodle, or
Journaling Suggestions mode. The action uses `UISceneAppIntent` and
`AppIntentSceneDelegate` to activate Journal and present the corresponding
in-app capture surface. It requires device authentication and does not capture a
camera image while the phone remains locked.

`JournalAppIntentsExtension` exposes **Quick Capture** and **Post Text to
Journal** to Shortcuts, Siri, Spotlight, and Action Button action selection.
Post Text runs in the background, accepts text from actions such as Dictate Text,
and commits to either its explicit writable Vault parameter or the Quick Capture
Vault. Its success boundary is the local Card transaction plus durable outbox;
it does not claim CloudKit upload is already complete.

`JournalShareExtension` presents a custom SwiftUI review sheet for text, web and
Maps URLs, images, movies, and individual files. The user can choose any writable
Vault, add an optional comment as the root Card, review skipped inputs, and post
all accepted items in one `createThread(cards:)` transaction. Generic files are
real `.file` Cards with their original display name, bytes, content type, and
size preserved. The explicit Quick Capture Vault is preselected when valid, but
the extension never silently substitutes another destination.

All system entry points share `JournalPostingService`. App extensions receive
only the App Group entitlement, never start CKSyncEngine, and open shared stores
with destructive pre-release recovery disabled. When the containing app becomes
active it rescans every durable outbox so cross-process writes enter the existing
CloudKit engine; widgets are reloaded immediately after the local commit.

### Entitlements & capabilities

Declared in `Project.swift` on the app target:

- `com.apple.developer.icloud-container-identifiers` = `iCloud.app.muukii.journal`
- `com.apple.developer.icloud-services` = `CloudKit`
- `com.apple.security.application-groups` = `["group.app.muukii.journal"]` —
  backs vault stores, Quick Capture preferences, and extension access. Declared
  on the app, Widget, App Intents, and Share targets.
- `aps-environment` = `$(APS_ENVIRONMENT)` — expanded per configuration
  (`development` for Debug, `production` for Release). Required so shipped builds
  receive CloudKit's silent pushes for background sync.
- `JournalCloudKitEnvironment` Info.plist key = `$(APS_ENVIRONMENT)` — lets
  `JournalVault` scope local App Group storage and launch-routing cache keys to
  the same CloudKit server environment as the entitlements.
- `com.apple.developer.journal.allow` = `["suggestions"]` — lets
  `CaptureSuggestions` present the system Journaling Suggestions picker. Note the
  value is a **string array**, not a boolean; it must match what the App ID's
  Journaling Suggestions capability writes into the provisioning profile or
  signing fails.

The `JournalWidget` target carries the same App Group, iCloud container,
CloudKit, and `aps-environment` entitlements as the app. Its live timeline read
is local App Group storage; CloudKit access remains available for future
extension-side recovery or summary refresh work.
The App Intents and Share targets carry only the App Group entitlement; CloudKit,
push, and background modes remain owned by the containing app.

### Usage descriptions (Info.plist)

- `NSCameraUsageDescription` — CapturePhoto.
- `NSPhotoLibraryUsageDescription` — choosing existing Photos media and reading
  Live Photo resources when a selected Live Photo needs its paired movie.
- `NSMicrophoneUsageDescription` — CaptureAudio.
- `NSLocationWhenInUseUsageDescription` — automatic location attachment for
  newly authored cards when the Journal setting is enabled.
- `CKSharingSupported` = `true` — lets CloudKit share URLs launch the app and
  deliver `CKShare.Metadata` to the scene delegate for invite acceptance.
- `UIBackgroundModes` = `["remote-notification"]` — lets the explicit CloudKit
  sync layer wake for remote change notifications while backgrounded.

---

## Data Model

Active app data lives in **`JournalVault`**. SwiftData is local persistence and
SwiftUI observation only; every vault content store is opened with
`cloudKitDatabase: .none`. CloudKit rows, assets, zones, shares, and remote
imports belong to the CloudKit sync coordinator.

The legacy local **`JournalModel`** schema is no longer part of the app project.
Journal does not keep a product migration path for that schema while the app is
pre-release.

### `VaultInstance` — UI-facing vault object

Each vault has one UI-facing `VaultInstance` in the app process. It owns the
vault's `VaultContentStore`, cached outbox count, foreground sync interest, and
future permission/share state. App screens use the selected `VaultInstance`
rather than reaching for CloudKit transport objects or opening their own
`ModelContainer`.

### `VaultContentStore` — one vault database

Each vault has its own SQLite store and media directory under the active
CloudKit environment's App Group layout:

```text
Journal/
  development/ or production/
    catalog.sqlite
    SyncState/
    Vaults/
      <vault-id>/
        store.sqlite
        media/
```

`VaultContentStore.createThread(cards:)` writes a root `CardEdge` plus child
edges in one transaction. The same transaction writes `PendingMutation` rows, so
local content never exists without a pending CloudKit upload.

SwiftData relationships are the normal in-app source of truth for vault content:
`CardEdge` points to its `Card` and parent/child edges, `Card` owns attachments,
and `Attachment` owns resources. Stable UUID reference fields remain alongside
those relationships so CloudKit imports can be repaired when records arrive out
of order.

### `Card` — a content atom

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Unique inside the vault store. |
| `kindRawValue` | `String` | Stored/synced modality string: `.text`, `.link`, `.file`, `.photo`, `.video`, `.livePhoto`, `.audio`, `.suggestion`, `.doodle`, `.bauhaus`, or a newer unknown value. `kind` maps unknown values to `.unknown`. |
| `body` | `String` | Text content for `.text`; canonical URL string for `.link`; original display name for `.file`; other media cards keep this empty. |
| `attachments` | `[Attachment]` | Relationship-owned media rows for this card. |
| `placements` | `[CardEdge]` | Relationship-owned placements that point at this card. |
| `createdAt` | `Date` | |
| `updatedAt` | `Date` | |
| `location` | `Coordinate?` | `nil` = no location. |

### `CardEdge` — a card placement in the vault tree

`CardEdge` is the fractal structure for both roots and children. A root edge has
no parent relationship; children point to another edge. A linear thread is a
root edge plus ordered child edges, and future mind-map layouts can attach layout
data without changing `Card`.

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Unique edge id. |
| `card` | `Card?` | SwiftData relationship to the placed card. |
| `children` | `[CardEdge]` | Child placements in the same vault tree. |
| `cardID` | `UUID` | Relationship-backed reference ID for sync/import repair. |
| `parentEdgeID` | `UUID?` | Relationship-backed parent reference ID, or `nil` for roots. |
| `sortIndex` | `Int` | Order among siblings. |
| `layout` | `Data?` | Reserved layout metadata. |
| `createdAt` | `Date` | |
| `updatedAt` | `Date` | |

### `Attachment` — media metadata for a Card

`Attachment` is the user-visible logical media item on a `Card`. Concrete files
belong to `AttachmentResource` rows, so one attachment can later represent a
compound media item such as a Live Photo.

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Unique attachment id. |
| `card` | `Card?` | SwiftData relationship to the owning card. |
| `resources` | `[AttachmentResource]` | File-backed resources owned by this logical attachment. |
| `cardID` | `UUID` | Relationship-backed reference ID for sync/import repair. |
| `kindRawValue` | `String` | `.file`, `.photo`, `.video`, `.livePhoto`, `.audio`, `.suggestion`, `.doodle`, `.bauhaus`, or unknown raw value. |
| `byteSize` | `Int` | Denormalized primary-resource byte size kept for summaries. |
| `primaryResourceID` | `UUID` | Primary resource used by normal rendering. |
| `thumbnail` | `Data?` | Optional save-time raster derivative for photo, video poster, and Live Photo still surfaces. Doodle/Bauhaus leave it empty and render from authored media. |
| `createdAt` | `Date` | |

### `AttachmentResource` — one CKAsset-backed media file

`AttachmentResource` is a domain row and local file identity, not a direct
reference to a `CKAsset`. The sync mapper turns its local file into a CKAsset
field when uploading and copies a downloaded CKAsset into the vault media
directory before the CloudKit temporary file disappears.

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Unique resource id and `media/<resource-id>` file name. |
| `attachment` | `Attachment?` | SwiftData relationship to the owning logical attachment. |
| `attachmentID` | `UUID` | Relationship-backed reference ID for sync/import repair. |
| `roleRawValue` | `String` | `.file`, `.originalImage`, `.stillImage`, `.pairedVideo`, `.originalVideo`, `.authoredJSON`, `.suggestionImage`, `.suggestionVideo`, `.audio`, or unknown raw value. |
| `byteSize` | `Int` | Resource file byte size. |
| `contentType` | `String?` | UTI/MIME-style content type when known. |
| `pixelWidth` / `pixelHeight` | `Int?` | Image/video dimensions when known. |
| `duration` | `Double?` | Video/audio duration in seconds when known. |
| `isHDR` | `Bool` | Whether the resource contains HDR media. |
| `colorSpaceName` | `String?` | Color space name when known. |
| `localFileRevision` | `Int` | Local-only revision bumped when a mirrored file lands or changes at the same URL. |
| `createdAt` | `Date` | |

### Card rendering boundary

Normal card surfaces render from the authored value when that value is cheap and
lossless to render. Text and link cards render their stored body/URL in SwiftUI;
file cards render the original name with a document icon, content type, and size.
Doodle and Bauhaus cards decode their saved JSON attachment and render
`DoodleDrawingView` / `BauhausGridArtworkView` directly as SwiftUI content; if
the vault media file has not arrived locally yet, the UI shows a modality
placeholder until SwiftData observes the resource's local file revision change
and reloads the preview payload.

Large raster media is the exception. Photo summary surfaces and Widget Home
Screen photo previews use the save-time `Attachment.thumbnail` created by
`MediaProcessing`, so scrolling lists and Widget timelines do not decode
original-size image files. Detail and editing flows still read the full media
file when they need the original captured payload. Future video cards should use
the same boundary for poster frames.

Raster images are generated only at explicit raster boundaries: media
thumbnails/posters, share/export images, video frames, APIs that require an
image payload, or narrow dev/debug previews.

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
app-shell growing multiline editor bound directly to `CardEditDraft.text`; Link
composition uses an app-shell URL field and LinkPresentation preview over the
same draft body slot, so typed changes are reflected in the draft immediately.

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

On macOS, AVFoundation selects the default video device (including a
built-in or Continuity Camera) without applying an iPhone front/back filter, and
the front/back flip control is hidden because that camera relationship does not
exist on Mac.

- `CapturedPhoto`: `Sendable, Equatable` — `imageData: Data` (JPEG bytes),
  `pixelSize: CGSize`, and a lazy platform-native decoded image (`UIImage` on
  iOS, `NSImage` on macOS).
- `CameraController` owns the `AVCaptureSession`, camera input, and still-photo
  output; `CameraPreviewView` mounts an `AVCaptureVideoPreviewLayer` in SwiftUI.
- Saving a photo card passes the JPEG bytes through `MediaProcessing`, which
  uses Image I/O to create an orientation-corrected thumbnail with a bounded
  maximum pixel length. The full JPEG remains the editable vault media file.
- Photos library import accepts still images, Live Photos, and videos. Live
  Photos become `.livePhoto` cards with one logical attachment: the still image
  is the primary `.stillImage` resource and the motion component is a
  `.pairedVideo` resource. Videos become `.video` cards with an `.originalVideo`
  primary resource and a save-time poster thumbnail.

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
The native macOS canvas has an AppKit input adapter so mouse and trackpad drags
enter the same timestamped vector-stroke pipeline; Command-Z invokes canvas undo.
The drawable surface is fixed to the same 4:5 portrait paper proportion as journal cards
(`width / height = 4 / 5`), and the toolbar is single-color: width slider,
undo, replay, clear, and export when `onExport` is supplied. When `onChange` is
supplied, the canvas emits the current
`DoodleDrawing?` after committed stroke changes, undo, or clear so hosts can
auto-save drafts.

- `DoodleDrawing`: `Sendable, Equatable, Codable` — `strokes: [DoodleStroke]`,
  `canvasSize: CGSize`, `duration: TimeInterval`. `DoodleDrawingView` renders
  the saved vector value directly as SwiftUI content; `image(inkColor:scale:)`
  is reserved for explicit raster outputs such as share/export or debug
  previews.
- `DoodleStroke`: `points: [DoodlePoint]` (each `x, y, time`, optional
  point-level `width`), `width: Double` base brush width.
- Supporting types: `DoodleCanvas` (controller), `DoodleStrokesView` (renderer),
  `StrokeSmoothing` (fixed streamline pipeline), `DoodleDrawingHaptics`,
  `DrawingGestureRecognizer` (timestamped), `TimedPoint`.

### CaptureBauhaus → `BauhausGridDocument`

`BauhausGridCaptureView(initialDocument:onChange:onExport:)` — a SwiftUI grid
composer for Bauhaus-style geometric artwork. The canvas is a fixed **5 x 5**
grid of square cells, slightly inset from the sheet width so more of the brush
panel remains visible without scrolling. A persistent brush panel below the
canvas lets the user choose one of the prepared primitives (square, filled
circle, padded circle, four arc-on-edge semicircles, four diameter-on-edge
semicircles, four quarter-circles, four edge-base triangles, and four diagonal
corner triangles), pick primitive/background swatch colors, preview the active
brush, switch to an eraser, or step through local undo/redo history. Tapping the
active brush preview cycles to the next primitive in its current family,
including the basic square/circle/padded-circle set, edge triangles, and
semicircles. Tapping a grid cell
immediately applies the current brush or clears that cell when the eraser is
active. The trash action clears the whole
artwork, and an optional export callback lets hosts finish the capture
explicitly. The picker groups primitives by family in fixed four-column rows so
directional variants stay visually aligned while the panel adapts to device
width. Every cell edit, clear, undo, and redo emits the current
`BauhausGridDocument` through `onChange`. New empty documents record a replay
timeline as cells are set or the grid is cleared; undo and redo restore the
matching in-session document state, including replay data. Documents decoded
from older final-only artwork stay static unless the user clears the grid and
starts again. Brush, eraser, and swatch selection use selection haptics; shape
application, clearing, undo, and redo use light impact haptics; and the optional
export action uses success feedback.
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
- The native macOS build cannot import Journaling Suggestions, so it compiles a
  fallback and excludes the compose entry point. The framework is also absent
  from the Designed-for-iPad runtime, which keeps `@_weakLinked` imports (a plain
  `import` re-strengthens
  the autolink and causes a dyld launch failure), plus the
  `ProcessInfo.isiOSAppOnMac` runtime guard and `AnyView` type erasure.
- Suggestions only appear on a **real device** with the Settings opt-in enabled,
  and the App ID needs the Journaling Suggestions capability so the managed
  profile carries the entitlement key. Min deployment iOS 26.1 (no `@available`
  gating needed).

---

## Supporting Frameworks

### MuColor — neutral appearance and key accent

A neutral app palette with one user-selectable key accent.

- `Palette`: six seed colors (`tint`, `onTint`, `primaryContainer`,
  `onPrimaryContainer`, `secondaryContainer`, `onSecondaryContainer`) plus
  opacity-derived variants (`onPrimaryContainerVariant`, `outline`,
  `outlineVariant`, `tintRing`, …). `onTint` is the foreground color for text and
  icons displayed directly on a tint/accent surface. Primary surfaces are pure
  white with black foreground in Light mode and pure black with white foreground
  in Dark mode. Secondary surfaces use only neutral gray for hierarchy. These
  surfaces never inherit the accent hue, so authored photos, doodles, Bauhaus
  artwork, and card colors remain visually independent.
- `AccentColor`: a persisted `id`, localized display `name`, and asset-backed key
  color. Five accents are available: **Forest** (default), **Cobalt**,
  **Vermilion**, **Orchid**, and **Amber**. Accent applies to selection, focus,
  and primary actions only. `AccentColor.with(id:)` also maps ids from the former
  ten-theme system to the closest current accent so existing preferences survive
  the migration.
- Container views `PrimaryContainer` / `SecondaryContainer` push a palette into
  the environment (`\.appPalette`) and apply background/foreground/tint.
  `PrimaryContainer(accentColor:)` resolves the accent's light/dark key color and
  the shared neutral surfaces from the
  current color scheme at the root; nested containers inherit the resolved
  palette. App shape styles (`.appPrimaryContainer`, `.appSecondaryContainer`, …)
  read the palette from the environment so accent and color-scheme changes
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

- **`TinycurveApp`** (`@main`) — builds `JournalVaultRuntime` and injects the
  persisted accent palette via `RootView` → `PrimaryContainer`. It does not open
  or inject the legacy `ModelContainer`.
- **`RootView`** — reads the persisted accent (`@AppStorage(JournalDefaults.accentColorID)`)
  and appearance preference
  (`@AppStorage(JournalDefaults.appearancePreferenceID)`), applies the palette,
  and requests the chosen scene color scheme. `System` follows the device
  appearance; `Light` and `Dark` override it for Journal. It is also the root
  router. On a fresh install, it starts in **Loading** while
  `JournalVaultRuntime` resolves initial vault availability: if iCloud is
  available, it performs the first CloudKit vault discovery pass by fetching
  Journal vault zones and each vault's lightweight `VaultInfo` title without
  waiting for card records or `CKAsset` media downloads; if iCloud is
  unavailable or unused, it resolves to local-only state; if iCloud is
  temporarily unavailable or cannot be determined, it resolves with deferred
  CloudKit recovery instead of blocking forever. A resolved decision records the
  active CloudKit environment's
  `JournalDefaults.hasResolvedInitialVaultAvailability` key. After the catalog
  refresh, a non-empty catalog always activates a vault before Home appears:
  `JournalDefaults.lastSelectedVaultID` is preferred when it still names a
  catalog vault, otherwise the first catalog vault is selected automatically.
  There is no user-visible selection-required state. A successful activation
  enters the persistent Creation-first Home without showing the picker. If no
  vault state exists and onboarding has not been completed, Root routes to **New
  User** onboarding. Completing onboarding records
  `@AppStorage(JournalDefaults.hasCompletedOnboarding)` and enters Home's
  **No Vaults** state. That state omits Creation, Entries, and Save actions; it
  offers **New Vault**, **Refresh**, and Settings directly. When initial iCloud
  recovery was deferred, No Vaults and the Vault sheet show a compact diagnostic
  banner, while Settings' debug-only **Vault Runtime** screen shows the last
  availability resolution. Root also owns the
  scene-local `JournalNotificationCenter` and wraps the app content in
  `JournalNotificationHost`, which injects that model through the SwiftUI
  environment and overlays app-wide bottom capsule notifications above the
  current screen. Incoming CloudKit vault invitations are bridged from UIKit
  scene metadata into `JournalVaultRuntime.acceptShare(metadata:)`; success
  completes onboarding if needed and activates the first available vault only
  when no vault is already active.
  The same root consumes buffered `UISceneAppIntent` capture requests after
  launch-time vault recovery, rejects missing/stale/read-only destinations
  without fallback, and rescans extension-written outboxes whenever the scene
  becomes active.
- **`JournalHomeView`** — the persistent post-onboarding presenter. Its normal
  states are Creation backed by an active vault and **No Vaults**. It owns the
  Vault sheet and direct first-vault creation sheet. On iOS it also owns the
  no-vault Settings sheet; on macOS its Settings action opens the app-level
  Settings scene, so changing or deleting a vault never replaces an active modal
  presenter.
  `CreationView` is keyed by the active `vaultID`, ensuring view-local drafts do
  not cross into a newly selected vault.
  A system capture request for another Vault keeps its typed request alive while
  this key changes, then presents from the replacement Creation view.
- **`VaultSelectionView`** — a medium/large sheet opened from the active vault
  label in Creation. It reads `JournalVaultRuntime.vaults`, shows the catalog in
  picker order as a standard SwiftUI `List`, marks the active vault with a
  checkmark, and calls `JournalVaultRuntime.selectVault(_:)` for another row.
  Selecting the current vault simply closes the sheet; another row closes it
  only after that vault opens successfully. Failed switches retain the previous
  active vault and leave the sheet visible. A successful manual selection,
  including a newly created vault, records that vault as
  `JournalDefaults.lastSelectedVaultID` for the next launch. The toolbar has
  **Done** and **New Vault** actions. Creating a vault calls
  `JournalVaultRuntime.createVault(title:icon:)`, seeds the local vault store,
  reloads the catalog, opens the new vault, and then dismisses the Vault sheet.
  Owned vault rows always show a separate share button inside
  the cell; once the catalog knows the vault has a CloudKit share, the row also
  shows a system `SWCollaborationView` control. This matches the Notes-style
  split between explicit invite issuance and collaboration state/management. The
  collaboration control registers an `NSItemProvider` for the vault's zone-wide
  `CKShare`, resolves that share only when the user opens the system
  collaboration UI, and limits sharing to specified recipients with read-write
  permission. The share button and row context menu both present the direct
  `UICloudSharingController` invite sheet; participant vault rows do not offer
  invite issuance. New vault creation keeps icon selection to one compact row
  in the form and drills into one **Icon** browser. Curated SF Symbols and the
  Unicode fully-qualified Emoji catalog share a single lazy-scrolling grid with
  no family tabs or section split. The always-visible search field filters both
  kinds together by SF Symbol name, English and Japanese Emoji names/keywords,
  or an Emoji pasted directly into the field. The grid shows one primary item
  for each skin-tone family; choosing that item opens a secondary palette with
  its exact neutral, single-tone, and mixed-tone variants. Existing vault rows
  show that icon in the picker, expose **Change
  Icon** from the row context menu, and carry the icon into the composer toolbar,
  storage estimate rows, and widget vault headers. Icon metadata is stored
  alongside the title in the vault's CloudKit `VaultInfo` record, so changes
  propagate to the owner's other devices and writable share participants.
  Legacy `VaultInfo` records without icon fields retain the receiving device's
  current catalog icon. Writable vault rows expose **Rename** from the row
  context menu. The rename sheet trims the entered title, rejects empty or
  unchanged titles, updates the vault's sync-visible
  `VaultInfo` title, mirrors it into the local catalog summary, refreshes widget
  timelines, and hides the action for read-only shared vaults. Vault rows can be
  deleted from the row context menu after a destructive confirmation.
  Owned vault deletion removes the CloudKit custom zone before deleting local
  catalog/content files, so the vault disappears for everyone with access.
  Participant vault deletion targets the accepted shared zone and then removes
  the local catalog/content files for this user. Deleting the active vault
  automatically activates the following catalog row, or the preceding row when
  the deleted vault was last; deleting the final vault dismisses the sheet and
  reveals Home's No Vaults state.
- **`OnboardingView`** — the first-run introduction, also re-showable on demand
  from Settings. Four horizontally-paged screens (`TabView` with
  `.tabViewStyle(.page)`) plus a fixed **Get Started** / **Next** call-to-action
  and a **Skip** affordance on every page but the last:
  1. **Welcome** — a decorative `CardSurface` stating the core idea ("Every little
     thing becomes a card") over a short welcome blurb.
  2. **Capture methods** — Text, Link, Photo, Doodle, and Ambient Sound as icon
     + name + one-line summary. iPhone and iPad builds also show Suggestions;
     native macOS omits it because the system framework is unavailable.
  3. **Permissions** — optional priming for Camera, Photos, Microphone, and
     Location. Each row shows the live authorization status and an **Allow**
     button that triggers the system prompt on demand
     (`AVCaptureDevice.requestAccess(for:)`,
     `PHPhotoLibrary.requestAuthorization(for: .readWrite)`,
     `AmbientAudioRecorder.requestPermission()`,
     `LocationManager.requestAuthorization()`); the user can advance without
     granting anything.
  4. **Accent Color** — a grid of five key colors bound to
     `JournalDefaults.accentColorID`. Journal surfaces remain neutral while the
     selected accent updates interactive chrome immediately.

  The view is presentation-agnostic — it reports completion through an
  `onComplete` closure and never writes `hasCompletedOnboarding` itself — and
  wraps its body in its own `PrimaryContainer` keyed to the stored accent so the
  palette resolves whether shown inline (first run) or over the app (Settings
  cover).
- **`CreationView`** — the selected-vault home and compose screen. The main
  surface embeds `SavedListView`, so cards already posted to the active vault
  remain visible while composing. Root cards are read live from the vault's
  SwiftData store, ordered newest first, grouped by local-calendar day, and
  rendered in the same adaptive 4:5 card grid, including existing stack,
  refresh, navigation, edit, share, and delete behavior. Posting targets the new
  root edge in this list so the newly created card is brought into view.
  When the selected owned vault is already shared, the navigation toolbar also
  shows the same system `SWCollaborationView` control used by the vault picker,
  keeping collaboration management available from Home. The control is derived
  from the refreshed catalog row, so it disappears after sharing is stopped and
  the runtime refreshes.

  Creation lives in a Book-style glass input bar inset at the bottom of the
  saved-card list. Its center is a multiline **Write a card** text field that
  grows from one to five lines; text currently inside this field is the one
  unpublished card, rather than a separate draft card displayed in the list.
  The trailing glass up-arrow posts that card and is enabled only when the
  current content is persistable: text must contain non-whitespace content, a
  link must resolve to a valid HTTP(S) URL, and capture-backed kinds must contain
  their completed payload. Command-Return invokes the same post action. On
  iOS, starting a drag on the saved-card scroller dismisses the inline text
  keyboard, including when the active vault has too few cards to scroll. On
  macOS, the bar is centered and capped at `720pt`; Command-Shift-V opens Vaults
  and Command-comma opens Settings.

  While the input is the untouched empty text card, the leading `+` opens a
  standard SwiftUI `Menu` containing Link, Camera, Photos, Bauhaus, Doodle,
  Voice, and feature-flagged Suggestions. Text needs no menu item because it is
  entered directly in the bar. The system owns menu placement, interaction,
  accessibility, and dismissal. Once the input is no longer the untouched text
  placeholder — including while it is in Link mode — the `+` becomes an
  `xmark`; choosing it requires destructive confirmation before the unpublished
  card is discarded. Changing vaults also requires confirmation while the input
  contains an unpublished card.

  Quick Capture requests use the same draft-preservation rule. With an empty
  composer they open the focused text editor, camera, voice recorder, doodle
  canvas, or system Suggestions picker directly. If unpublished input exists,
  Journal asks before discarding it; cancelling consumes the system request and
  leaves the draft unchanged.

  Link, Camera, Photos, Bauhaus, Doodle, Voice, and Suggestions reuse that same
  single card rather than appending another draft. Link capture uses URL-keyboard
  input and normalizes values such as `example.com` to HTTPS. Camera writes a
  `CapturedPhoto`; Photos uses the system picker and imports still images,
  videos, or Live Photos while preserving the paired Live Photo resources. A
  failed library import leaves the current input in place and shows a persistent
  failure notification. Doodle and Bauhaus present native sheets at the large
  detent and stream non-empty vector/grid changes into the card; clearing the
  canvas or grid restores the empty text input. Voice writes the completed
  `AudioRecording`. After a non-text capture completes, the input bar shows a
  preview rendered from the actual authored payload. Valid Links use a large
  native rich-link surface; Photo, Video, Live Photo, Doodle, and Bauhaus use a
  large square visual; Audio uses a wide horizontal waveform. These expanded
  surfaces occupy only the center column between the leading discard and
  trailing post buttons, and do not repeat the kind as visible text. An
  incomplete Link and the remaining non-text kinds keep the compact preview and
  modality label. Tapping a preview opens the matching detail editor without
  allowing the card kind to be switched;
  imported video, Live Photo, and Suggestion details are preview-only, while
  supported authored formats remain editable.

  The Suggestions action presents Apple's Journaling Suggestions picker. One
  picker selection becomes one aggregate Suggestion card containing the returned
  title, date interval, and all resolved top-level elements; it does not fan the
  elements out into a creation-time chain. The authored payload is stored as JSON
  rather than in the card body. When source files are locally available, photos,
  videos, Live Photo components, posters, artwork, and icons are copied into
  additional suggestion media resources and referenced from that payload.
  Previews use the first element as the primary subject and summarize remaining
  elements. The resolver supports Contacts, Event Posters, Generic Media, Live
  Photos, Locations, Location Groups, Motion Activity, Photos, Podcasts,
  Reflections, Songs, State of Mind, Videos, Workouts, Workout Details, and
  Workout Groups; transient SwiftUI decoration values such as suggestion
  gradients/colors are not persisted.

  When the Settings **Attach Location** preference is enabled, the composer asks
  for a one-shot coordinate only after the card becomes persistable and attaches
  it to that unpublished card. Disabling the preference or losing location
  authorization clears the in-progress coordinate; posting still succeeds
  without location when no coordinate is available. The saved-card list shows a
  compact, wide map header whenever the selected vault contains located cards.
  This header stays zoomed around the most recently created located card and
  overlays pins for saved cards in that area while the normal card grid remains
  directly below it. Tapping the header pushes an interactive **Map** screen
  whose initial camera frames every located card in the selected vault. Nearby
  or overlapping pins automatically group into a count marker and separate into
  individual pins as the user zooms in. The up-arrow freezes one save snapshot,
  converts it into one `VaultContentStore.CardDraft`, and calls
  `createThread(cards:)` with that single value. This immediately persists one
  root `CardEdge`, clears the input only after success, refreshes the vault and
  widget, and scrolls the embedded saved-card list toward the new root. The
  Photo, Video, and Live Photo write paths generate or carry a bounded
  thumbnail; Doodle, Bauhaus, and Suggestion retain authored payloads, with
  Suggestion media copied alongside its JSON when available.

  Successful posting shows a transient **Posted to Journal** notification with
  success haptics. If posting fails, the unpublished card stays in the input bar
  and a persistent **Could not post** notification states that the input is still
  present, with failure haptics. Notifications fade, blur, and scale in place
  with a slight bounce instead of sliding from an edge. Creation-time chains are
  intentionally not exposed: each press of the up-arrow posts exactly one new
  root card. A future continuation flow is planned as a reply to an already
  saved card rather than accumulating several unpublished cards before posting.
  Capture demos remain in the dev gallery rather than Settings.
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
  `VaultInstance`. It attaches the selected vault's `ModelContainer`, queries
  `CardEdge` rows with SwiftData, follows the `Card` / `Attachment` /
  `AttachmentResource` relationships, groups root edges into local-calendar day
  sections, and displays them as 4:5 `CardSurface` tiles. Child edges are
  collapsed into the root tile by default and shown in the pushed detail view as
  a flattened subtree. When any saved thread has child cards, the toolbar shows a
  stack toggle: collapsed mode keeps one tile per root stack, while expanded mode
  flattens root and child cards into the day grid from the live model graph.
  Collapsed stacks keep lightweight child previews behind the root tile and use
  matched-geometry animation so expansion feels like cards moving out of the
  stack. Tile timestamps sit over a bottom `.thinMaterial` layer whose alpha is
  masked with a soft Gaussian gradient, so the preview fades into the footer
  instead of ending at a hard material edge. Pull-to-refresh asks the vault
  runtime to import fresh CloudKit changes;
  the old toolbar reload icon is not shown in the normal list surface. Grid tiles
  are matched transition sources so opening a detail view uses the system zoom
  navigation transition from the tapped card. Link cards
  use iOS's LinkPresentation preview in both tiles and detail rows, fetching
  metadata at display time and caching it for the app session. Photo summary
  previews use the saved thumbnail to avoid decoding original-size images during
  scrolling. Compact tiles remain on the shared 4:5 `CardSurface`, while the
  pushed detail view presents authored content without a common card shape,
  rounded clipping, stroke, or fixed height. Text uses its natural height;
  Photo, Video, and Live Photo use the persisted pixel dimensions (falling back
  to decoded media dimensions) and aspect-fit the complete image without crop.
  When a card has a location, its detail row shows a slender, non-interactive
  street map centered on the recorded point between the authored content and
  record metadata. The card kind, created/updated timestamps, and edit/delete
  controls sit below it. Detail rows can still read the full vault media file and retain
  detail-only Link and Live Photo interaction. Video previews
  play as muted inline loops when the media file is local, while keeping the app
  audio session mixed with other audio so external music or podcasts continue.
  Doodle and Bauhaus previews decode the authored JSON attachment file and render
  it with their SwiftUI renderers. When a media file is not local yet, the UI
  shows a modality placeholder; when sync writes the file and bumps the resource
  revision, SwiftData observation re-runs the affected preview load. Saved cards
  can be shared from a grid tile's context menu
  or a detail row's context menu. The share action opens a preview sheet backed
  by a detached share snapshot, renders the actual temporary PNG artifact,
  and, for Doodle or Bauhaus cards with authored replay data, also offers a
  generated mp4 replay before handing the selected file to the system activity
  sheet. Saved cards can be edited from a grid tile's context menu or from each
  detail row's pencil button. Editing rehydrates the saved card into
  `CardEditDraftEditor`, requires the full media file for media cards, and saves
  back through `VaultContentStore.updateCard(cardID:with:)`; thumbnails are not
  used as lossy edit sources. Saved cards can also be deleted from a grid tile's
  context menu or from each detail row's trash button. Deletion is confirmed
  first, then writes through `VaultContentStore.deleteCardEdge(edgeID:)` so the
  selected edge, descendant cards, attachments, attachment resources, local media
  files, and CloudKit delete outbox rows stay aligned. Detail deletion dismisses
  back to the list after a successful delete so the user sees the updated model graph.
- **`SettingsView`** — an **Accent Color** picker, an **Appearance** picker, a **Location**
  toggle for automatic location attachment, an explicit **Quick Capture Vault**
  picker, a **Storage** section with **Cloud
  Storage** estimates, a **Widgets** section with an **Add Widgets** guide,
  optional Debug-only **Vault Runtime** and Lab links, and About actions.
  Settings is a grouped `Form`, but every cell background opts into the
  neutral `MuColor` secondary container because SwiftUI form rows do not inherit
  the app surface automatically. Selecting an accent writes
  `JournalDefaults.accentColorID` (animated) and triggers selection haptic feedback.
  The Appearance segmented picker writes
  `JournalDefaults.appearancePreferenceID`; **System** follows the device
  setting, while **Light** and **Dark** request a fixed scene color scheme for
  Journal and update the neutral palette immediately. The **Attach Location**
  toggle writes `JournalDefaults.shouldAttachLocationToNewCards`; it defaults on,
  and when disabled new draft cards are saved without location metadata. The
  Quick Capture selection is environment-scoped App Group state and lists only
  writable Vaults. Missing, deleted, or read-only selections require an explicit
  replacement instead of falling back to the last-opened Vault. **Cloud
  Storage** opens a Settings detail screen that estimates Journal's CloudKit
  payload from local vault rows: owned vaults are grouped as data that counts
  toward the user's iCloud quota, participant vaults are grouped as shared data
  charged to the originating owner, and breakdowns show text/link body bytes,
  media file bytes, thumbnail bytes, record counts, and media kind totals. It is
  labeled as an estimate because CloudKit does not expose exact iCloud usage or
  server overhead to the app. **Add Widgets** opens a Settings detail screen with
  an illustrated header and
  step-by-step instructions for adding Tinycurve to the Home Screen, Lock Screen
  below the clock, and StandBy. The guide frames the widget as showing the
  latest card in a chosen vault.
  On iPhone and iPad, the toolbar action continues to present
  `SettingsScreen` as the existing dismissible sheet, including its zoom
  transition from Creation. The sheet uses form presentation sizing so SwiftUI
  chooses a compact settings width on iPad while retaining the platform-native
  sheet treatment on iPhone. On native macOS, `TinycurveApp` declares a SwiftUI
  `Settings` scene instead: the application menu and Command-comma open one
  system-managed Settings window, toolbar actions target that same window, and
  the window's standard close control replaces an in-content dismiss button.
  The independent scene receives the same `JournalVaultRuntime`, theme, and
  appearance preference as the main window. Its size remains stable while
  navigating between Settings pages rather than resizing around each detail.
  Capture demos are intentionally hidden from Settings. In Debug builds, **Lab**
  links to Haptics and Haptic Doodle so those tools can be tried from the current
  app root; Release builds omit the Lab section. An **About** section has
  **Help**, which opens a practical support screen for iCloud sync, deleting
  owned versus shared vault data, Cloud Storage estimates, widgets, privacy, and
  Debug-only development/production CloudKit environment guidance; **Privacy
  Policy**, which opens an in-app policy explaining local storage, iCloud Private
  Database sync, optional permissions, sharing, widgets, and the absence of
  developer-operated analytics/ads/tracking; plus **Show Onboarding**, which
  re-presents `OnboardingView` in a full-screen cover on iOS and a native sheet
  on macOS;
  dismissing it returns to the app without changing `hasCompletedOnboarding`.

---

## Build & Run

This is a Tuist project; the `.xcodeproj` is generated. From the repo root:

```bash
tuist install
tuist generate
xcodebuild -workspace MuApps.xcworkspace -scheme Tinycurve \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -workspace MuApps.xcworkspace -scheme Tinycurve \
  -destination 'platform=macOS,arch=arm64' build
```

Each capture component also has its own scheme (`CaptureText`, `CapturePhoto`,
`CaptureDoodle`, `CaptureBauhaus`, `CaptureAudio`, `CaptureSuggestions`,
`MediaProcessing`, `MuColor`, `MuHaptics`) for building/running it in isolation.
`JournalIntents`, `JournalIntentsTests`, `JournalAppIntentsExtension`, and
`JournalShareExtension` are generated as separate schemes for system-capture
build and test verification.

**Simulator note:** this machine has no iPhone 16 simulator — use **iPhone 17 /
OS 27.0**.

**Mac signing note:** a native macOS build containing CloudKit and App Group
capabilities must be signed with an Apple Development certificate. An unsigned
or ad-hoc build can compile but cannot launch the product runtime truthfully.

### iCloud / CloudKit verification

The active app shell disables SwiftData CloudKit mirroring for vault stores.
CloudKit verification now belongs to `CloudKitVaultSyncEngine`: zone creation,
record upload/download, CKAsset file transfer, subscriptions, share creation,
share invitation acceptance, vault zone deletion, and shared-database imports.
The app runtime now uses `CloudKitVaultSyncEngine`; `LoggingVaultSyncEngine`
remains for previews, debug probes, and narrow tests.
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
