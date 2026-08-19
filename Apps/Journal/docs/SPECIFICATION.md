# Journal — Specification

The current, factual state of the `Journal` app. Update this whenever a
functional change lands (see [Documentation Policy](#documentation-policy)).

---

## Overview

`Journal` is a journaling app for iPhone, iPad, and native macOS. Each thing a
user records — text, a Todo, a shared file, a photo, a doodle, Bauhaus grid
artwork, ambient sound, or (on supported iPhone/iPad hardware) a Journaling
Suggestion — keeps a presentation suited to that content instead of being
forced into one shared card shape. `Card` remains the internal persisted
content-row name.
iCloud sync and vault collaboration are hard product requirements, so
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
  then writes text, Todo, link, photo, audio, doodle, and
  Bauhaus content into the selected `VaultInstance` through content-specific editors,
  plus a **dev gallery**
  (`CaptureGalleryView`) that launches each component standalone for on-device
  testing. The dev gallery is scaffolding, **not the shipping entry point**.
- A **theming system** (`MuColor`) and **Core Haptics labs** (`MuHaptics`).
- A **vault-selectable widget**: `JournalWidget` lets each widget instance choose
  one vault and reads the latest entry from that vault's App Group store.
- **System capture entry points**: a configurable Control for Action Button /
  Control Center, App Shortcuts and a background text-posting intent, and an iOS
  Share Extension for text, links, photos, videos, and files. The most recent
  successful Share destination becomes the implicit Vault for system capture
  entry points that do not carry an explicit Vault. Locked Camera Capture is
  intentionally not part of this feature.

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
default scheme, executable, module, and user-facing bundle display name are
`Tinycurve`; the WidgetKit extension bundle display name is `Tinycurve Widget`.
The shared `Tinycurve Production` scheme runs the debug-variant
`DebugProduction` configuration with a debugger while selecting the CloudKit
Production database on a physical iOS device or native Mac. Simulator remains
on CloudKit Development. The scheme intentionally defines no test targets.
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
├── ImageCropper       — development-only profile-image pan/zoom and square JPEG export
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

When the development-only `TINYCURVE_PROFILE_IMAGE` compilation condition is
enabled, the current user's optional profile image is app-global identity data,
not Vault content. `JournalUserProfile` reads and writes the custom
`profileImage` CKAsset field on CloudKit's public system `Users` record and is
injected independently from `JournalVault`. `ImageCropper` accepts encoded image
`Data` and returns a neutral square JPEG, keeping its pan/zoom geometry and any
future Brightroom implementation private to that module. The condition is set
only by the normal `Debug` configuration; `DebugProduction`, `Release`,
TestFlight, and App Store builds do not construct the profile model or expose its
UI while the feature remains under review.

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
the standard `Debug` configuration and all iOS Simulator builds read and write
`Journal/development`, while physical-device/native-Mac `DebugProduction`,
`Release`, TestFlight, and App Store builds read and write `Journal/production`.
Each environment owns its own catalog, per-vault stores, media files, and
CKSyncEngine state so development records, production records, change tokens,
and archived `CKRecord` system fields do not cross environments.

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
App Group and resolves the newest active root `CardEdge`
(`parentEdgeID == nil && deletedAt == nil`) by creation date. Continuations and
logically deleted entries are never eligible for the Latest Note widget,
including when a child was authored more recently than every root. It shows
kind-aware content: text uses `Card.body` (falling back to `Untitled`), Todo
uses `Card.body` plus the read-only state derived from `completedAt`, links use
their stored URL string, photos use the save-time raster thumbnail stored on
their attachment, files show their original name and type/size metadata, and
doodle / Bauhaus content decodes its authored JSON attachment and renders
`DoodleDrawingView` / `BauhausGridArtworkView`. Audio entries still show a typed
modality label because there is not yet a visual authored renderer for audio.
The Home Screen families show the selected vault title, latest-root body,
rendered visual media, or audio label plus the relative timestamp; the Lock
Screen accessory families use short labels or symbols that fit the tighter
surfaces. Native macOS exposes the small / medium / large families; the Lock
Screen accessory families remain iOS-only because WidgetKit does not make them
available on macOS.
It maps the `Card` to a `Sendable` `NoteSnapshot` so the timeline entry and
views stay free of live SwiftData model references; it shows an empty state when
there are no vaults or when the chosen vault has no entries.

New entry saves, saved-entry edits, and Todo completion changes request
`WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)` so
configured widgets refresh promptly. The 15-minute periodic timeline refresh
remains only for relative-date freshness. Future optimization can denormalize
latest-root previews into `VaultSummary`, but current product behavior reads the
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
and commits to either its explicit writable Vault parameter or the Vault used by
the most recent successful Share post. An explicit per-action Vault always wins.
Its success boundary is the local Card transaction plus durable outbox; it does
not claim CloudKit upload is already complete.

`JournalShareExtension` presents a custom SwiftUI review sheet for text, web and
Maps URLs, images, movies, and individual files. The user can choose any writable
Vault, add an optional comment as the root Card, review skipped inputs, and post
all accepted items in one `createThread(cards:)` transaction. Generic files are
real `.file` Cards with their original display name, bytes, content type, and
size preserved. The Vault from the most recent successful Share post is
preselected when it remains writable. The preference changes only after the local
post transaction succeeds; cancellation and failed posting leave it unchanged.
The extension never silently substitutes another destination when the remembered
Vault is missing or read-only.

All system entry points share `JournalPostingService`. App extensions receive
only the App Group entitlement, never start CKSyncEngine, and open shared stores
with destructive pre-release recovery disabled. When the containing app becomes
active it rescans every durable outbox so cross-process writes enter the existing
CloudKit engine; widgets are reloaded immediately after the local commit.

### Entitlements & capabilities

Declared in `Project.swift` on the app target:

- `com.apple.developer.icloud-container-identifiers` = `iCloud.app.muukii.journal`
- `com.apple.developer.icloud-container-environment` =
  `$(CLOUDKIT_ENVIRONMENT)` — selects CloudKit `Development` for `Debug` and
  CloudKit `Production` for `DebugProduction` and `Release` on supported signed
  destinations. Simulator overrides both to `Development`, matching CloudKit's
  platform constraint. Declared on the app and Widget targets.
- `com.apple.developer.icloud-services` = `CloudKit`
- `com.apple.security.application-groups` = `["group.app.muukii.journal"]` —
  backs vault stores, Quick Capture preferences, and extension access. Declared
  on the app, Widget, App Intents, and Share targets.
- `aps-environment` = `$(APS_ENVIRONMENT)` — expanded per configuration
  (`development` for `Debug` and `DebugProduction`, `production` for `Release`).
  This signing and push axis is intentionally independent from the CloudKit
  server environment. Required so shipped builds receive CloudKit's silent
  pushes for background sync.
- `JournalCloudKitEnvironment` Info.plist key = `$(CLOUDKIT_ENVIRONMENT)` — set
  on the app, Widget, App Intents, and Share bundles so every host process scopes
  local App Group storage and launch-routing cache keys to the same CloudKit
  server environment as the app's signed entitlement.
- `com.apple.developer.journal.allow` = `["suggestions"]` — lets
  `CaptureSuggestions` present the system Journaling Suggestions picker. Note the
  value is a **string array**, not a boolean; it must match what the App ID's
  Journaling Suggestions capability writes into the provisioning profile or
  signing fails.

The `JournalWidget` target carries the same App Group, iCloud container,
CloudKit environment, CloudKit service, and `aps-environment` entitlements as the
app. Its live timeline read is local App Group storage; CloudKit access remains
available for future extension-side recovery or summary refresh work. Native
macOS app and Widget builds declare the same CloudKit environment in their
static entitlements files because those replace Tuist-generated entitlements.
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
`VaultContentStore.appendCard(_:to:)` applies the same transaction boundary to
one continuation: it validates the parent edge, assigns the next direct-sibling
order, and writes the Card, child CardEdge, optional attachment/resources, and
their outbox saves together.

`VaultContentStore.deleteCardEdge(edgeID:)` is a logical local delete at the
placement boundary. It gives every `CardEdge` in the selected subtree one
`deletedAt` timestamp and queues CloudKit deletes for the subtree's edge, card,
attachment, and resource records in the same transaction. The local `Card`,
`Attachment`, `AttachmentResource`, and media files remain attached to the
SwiftData context. CloudKit acknowledgement removes only `PendingMutation` and
`SyncMetadata`. Trash UI, restore, retention, and physical purge are separate
future work.

SwiftData relationships are the normal in-app source of truth for vault content:
`CardEdge` points to its `Card` and parent/child edges, `Card` owns attachments,
and `Attachment` owns resources. Stable UUID reference fields remain alongside
those relationships so CloudKit imports can be repaired when records arrive out
of order.

### `Card` — a content atom

| Property | Type | Notes |
|----------|------|-------|
| `id` | `UUID` | Unique inside the vault store. |
| `kindRawValue` | `String` | Stored/synced modality string: `.text`, `.todo`, `.link`, `.file`, `.photo`, `.video`, `.livePhoto`, `.audio`, `.suggestion`, `.doodle`, `.bauhaus`, or a newer unknown value. `kind` maps unknown values to `.unknown`. |
| `body` | `String` | Text content for `.text` and `.todo`; canonical URL string for `.link`; original display name for `.file`; other media cards keep this empty. |
| `completedAt` | `Date?` | Todo completion timestamp. `nil` means incomplete; non-Todo cards normalize it to `nil`. `isCompleted` is derived and is not persisted separately. |
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
| `deletedAt` | `Date?` | Local-only logical deletion timestamp. It is not a CloudKit field; a recreated remote edge clears it. |

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
| `waveformData` | `Data?` | Optional versioned Codable JSON containing the recorded-audio meter history. The audio file remains the source of truth. |
| `isHDR` | `Bool` | Whether the resource contains HDR media. |
| `colorSpaceName` | `String?` | Color space name when known. |
| `localFileRevision` | `Int` | Local-only revision bumped when a mirrored file lands or changes at the same URL. |
| `createdAt` | `Date` | |

### Content rendering boundary

`EntryContentView` performs only exhaustive routing. Text, Todo, Link, File,
Photo, Video, Live Photo, Audio, Suggestion, Doodle, Bauhaus, and Unknown leaf
views each own a concrete `Style`. The `.composer` preset serves the compact
authoring preview, while `.cell` is the ordinary Home-tree presentation.
The router adds no minimum-height layout; each leaf derives its own intrinsic,
preview-height, or authored aspect-ratio geometry.
Share/export does not add a content preset: a 360 x 640pt `ShareFrame` wraps the
ordinary read-only content, centers it inside a 32pt safe inset, and
rasterizes the complete hierarchy uniformly to the default 1080 x 1920px
artifact. Text and link content render their stored body/URL in SwiftUI; file
content renders the original name with a document icon, content type, and size.
Todo content owns its completion indicator, completed typography, and read-only
presentation while feature code supplies the persistence action for editable
Home tree placements and export remains noninteractive.
Audio content receives only validated quantized levels from the feature
projection. It summarizes the full recording with peak-per-time-bucket bars for
the current placement; missing, malformed, or unsupported waveform payloads use
the existing decorative fallback waveform without making the audio unavailable.
Audio content also owns a play/pause control beside its waveform. Every
placement plays through one shared player, so starting a recording stops
whichever recording was already playing, and a recording keeps playing while its
card scrolls out of view. While a recording plays, the app takes the audio
session as spoken content — audible with the ring switch silenced, ducking other
audio instead of stopping it — and hands the session back to the muted inline
video mixing policy when playback ends.
The CloudKit storage estimate counts the encoded payload as inline record data
and exposes it under **Audio Waveforms** in the app-wide and per-vault breakdowns.
Doodle and Bauhaus content decode their saved JSON attachment and render
`DoodleDrawingView` / `BauhausGridArtworkView` directly as SwiftUI content; if
the vault media file has not arrived locally yet, the UI shows a modality
placeholder until SwiftData observes the resource's local file revision change
and reloads the content projection.

Large raster media is the exception. Photo summary surfaces and Widget Home
Screen photo previews use the save-time `Attachment.thumbnail` created by
`MediaProcessing`, so scrolling lists and Widget timelines do not decode
original-size image files. Home tree and editing flows still read the full media
file when they need the original captured payload. Future video content should use
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
- Saving a photo entry passes the JPEG bytes through `MediaProcessing`, which
  uses Image I/O to create an orientation-corrected thumbnail with a bounded
  maximum pixel length. The full JPEG remains the editable vault media file.
- Photos library import accepts still images, Live Photos, and videos. Live
  Photos become `.livePhoto` entries with one logical attachment: the still image
  is the primary `.stillImage` resource and the motion component is a
  `.pairedVideo` resource. Videos become `.video` entries with an `.originalVideo`
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
The drawable surface uses its own 4:5 portrait paper proportion
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
exposing live duration and normalized input levels for a scrolling waveform.

- `AudioRecording`: `Sendable, Equatable, Codable` — `fileURL: URL` (temp dir;
  host must move it to keep it), `duration: TimeInterval`, and optional
  `waveform: AudioWaveform`.
- `AudioWaveform`: versioned `Codable` value with a nominal sample interval and
  the complete ordered meter history quantized from `0...1` to `0...255`. Its
  JSON representation encodes the byte `Data` as Base64.
- `AmbientAudioRecorder`: `@MainActor @Observable` — `state` (`idle` /
  `recording` / `finished`), `duration`, `samples: [Float]` (rolling
  normalized-amplitude window, fixed length 48, ~2.4s at a 50ms poll). Static
  `requestPermission()` / `permission`. `start()` throws; `stop()` returns the
  `AudioRecording` with every level measured during that take. The rolling UI
  window resets after stop while the completed waveform stays on the returned
  value. Level mapping is linear-in-dB above a −50dB silence floor so the meter
  tracks perceived loudness.
- The recording surface keeps 48 bars visible and draws them in one synchronous
  `Canvas` pass. `TimelineView(.animation)` derives horizontal travel from the
  newest sample time, moving every measured bar left by one slot over the next
  50ms instead of repeatedly retargeting per-bar springs. The timeline pauses
  outside active recording; metering and persisted waveform data remain at the
  same nominal 20Hz cadence.
- On iOS, the recording category enables Bluetooth HFP input plus high-quality
  Bluetooth recording, so supporting AirPods-class microphones record above
  telephone quality while older hardware silently keeps HFP. The recorder's
  default **Automatic** choice prefers a connected wireless microphone such as
  AirPods, otherwise preserving a valid current route before falling back to
  the built-in microphone. The recording surface shows the resolved microphone
  and lets the user choose any currently available input before recording.
  Input choice is transient to that recording surface; a disconnected explicit
  input falls back to Automatic. Routing is **best-effort**: the recorder waits
  up to ~1.5s for a requested input to become active, then records on whatever
  route the system settled on and shows that input — a slow or declined
  Bluetooth handover changes the displayed microphone instead of failing the
  take. Native macOS input selection and output-route selection are outside
  this contract.
- **Channel modes (iOS):** recordings are mono by default. When the resolved
  microphone exposes stereo-capable data sources (the built-in microphone array
  on a physical device), a segmented control appears under the microphone
  selector offering **Mono / Stereo · Front / Stereo · Back**. Stereo takes set
  the data source's polar pattern to stereo, match the input orientation to the
  interface orientation at start (fixed for the take), and produce a 2-channel
  AAC file; the live meter shows the louder channel. The choice is transient to
  the surface and falls back to Mono when the selected input cannot record
  stereo — or when the active session does not actually grant two input
  channels after the stereo request (`inputNumberOfChannels` is the authority
  per WWDC20 session 10226; another app controlling routing can deny the
  preference). The Simulator (no data sources) records mono only.
- **Interruption:** if the system interrupts an active recording (phone call,
  Siri), the surface stops the take and delivers the partial recording through
  `onFinish` — audio captured before the interruption is kept instead of the
  surface staying stuck in a dead recording state.

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
  artwork, and authored content colors remain visually independent.
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
  notice. No Vaults gives it a standalone banner surface; the Vault sheet uses
  the existing List row surface without nesting another rounded background.
  Settings' debug-only **Vault Runtime** screen shows the last availability
  resolution. Root also owns the
  scene-local `JournalNotificationCenter` and wraps the app content in
  `JournalNotificationHost`, which injects that model through the SwiftUI
  environment and overlays app-wide bottom capsule notifications above the
  current screen. Incoming CloudKit vault invitations are bridged from UIKit
  scene metadata into `JournalVaultRuntime.acceptShare(metadata:)`; success
  completes onboarding if needed and activates the first available vault only
  when no vault is already active.
  `SystemNotificationAuthorization` is a separate app-scoped controller; it
  does not use the scene-local `JournalNotificationCenter` overlay. The app
  delegate installs `UNUserNotificationCenterDelegate` before launch completion
  on iOS and native macOS, registers APNs on launch and active recovery even
  when alert permission is denied, and never sends the device token to an app
  server. A CloudKit visible Pulse notification is allowed to use the system
  UI in foreground (`banner`, `list`, and `sound`) without rebuilding it as a
  local notification or suppressing it for the current Vault. A contextual
  primer requests only alert and sound after a confirmed collaboration boundary:
  owner share save plus dismissal, participant acceptance plus initial import,
  or the first open of an already collaborative Vault. Permission state remains
  app-scoped, while only one active scene at a time claims the primer
  presentation so multiple macOS windows cannot show duplicate alerts. The root
  also starts `SharedWithYouNoticeDeliveryCoordinator` and drains every local
  Vault on launch and when a scene becomes active, recovering ready notices
  authored by extensions or App Intents that never reached this process's
  in-memory event stream.
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
  Vault rows show at most one inline sharing action. Until a live zone-wide
  share has been fetched, owned vault rows show an explicit share button whose
  icon carries the catalog sharing state: an unshared vault uses
  `person.fill.badge.plus`, while a catalog-known shared vault uses
  `person.2.fill`. It opens a platform collaboration activity that registers
  the runtime's saved zone-wide `CKShare` on an `NSItemProvider`: iOS uses
  `UIActivityItemsConfiguration` with `LPLinkMetadata`, and native macOS uses
  an `NSSharingServicePicker` preview item. Once the runtime has fetched the
  zone-wide share, the row replaces that button with a compact (36pt) system
  `SWCollaborationView` control. The
  collaboration control registers the saved zone-wide `CKShare` on its
  `NSItemProvider` (an existing-share registration, not a lazy preparation
  handler), so the system treats the vault as already collaborated and its
  popover shows the collaboration state with the manage action. Sharing stays
  limited to specified recipients with read-write permission. Opening the Vault
  sheet re-fetches the zone-wide share for every shared vault; that fetch also
  self-corrects the catalog summary (participants accepted or the share stopped
  on another device). Sharing state itself is discovered from CloudKit: initial
  vault discovery, sync-engine record fetches, and invite acceptance all mirror
  the zone-wide `CKShare` (shared flag, participant count, this user's
  permission) into the catalog, so a reinstall or the user's second device shows
  correct status without opening the share sheet. The explicit share button
  and the row context menu both present that collaboration activity; participant
  vault rows do not offer invite issuance but do show the collaboration control
  for their accepted share. The app-lifetime `CKSystemSharingUIObserver` routes
  system save / stop callbacks through the runtime, while view delegates retain
  immediate UI feedback. The app posts a Shared with You update only for the
  origin device's eligible local `VaultActivity` after that Activity's CloudKit
  save acknowledgement: a root maps to `.edit`, a Reply maps to `.comment`.
  It resolves the catalog's saved share URL through the system collaboration
  highlight API and records `attempted` before posting, preferring a possible
  one-notice loss after a crash over a duplicate Messages notice. Remote imports
  never create or repost that local intent. The source entitlement contract is
  `com.apple.developer.shared-with-you.collaboration = true` and
  `com.apple.developer.shared-with-you = true`; App ID configuration, regenerated
  provisioning profile, and a signed-device effective-entitlement check remain
  required external release gates. New vault creation keeps icon selection to one compact row
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
  Debug builds add **Record Counts** to the row context menu. It opens a sheet
  that reads the vault's local SwiftData rows for every CloudKit record type
  immediately, then counts the records CloudKit currently stores in that vault's
  zone, and shows both as `local / iCloud` per record type plus totals, records
  CloudKit holds that this device has not imported yet, and the durable outbox
  depth. `CKSyncEngine` publishes no import progress, so a vault that still
  looks empty after a reinstall cannot otherwise be told apart from a finished
  import. The CloudKit read is a diagnostics probe: it enumerates the zone with
  its own change token and requests no record fields, so it neither advances
  sync tokens nor downloads media. A refresh action re-runs both sides, and a
  CloudKit failure is shown in the sheet without affecting sync.
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
  1. **Welcome** — a content-first statement ("Words, photos, and sounds each
     keep their own shape") over a short welcome blurb. When the page first
     appears, a `TextRenderer` reveals that statement glyph by glyph from
     leading to trailing, resolving blur and a small downward offset into the
     authored layout. Reduce Motion presents the completed statement immediately.
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
  surface embeds `SavedListView`, so entries already posted to the active vault
  remain visible while composing. Home selects root placements from the vault's
  live SwiftData graph as chronological grouping anchors, orders those roots
  newest first, and groups them by local-calendar day. Each anchor renders its
  complete active subtree inline, using `CardEdge.edgeID` as placement identity;
  descendants do not become independent Home items or day-grouping anchors.
  Home is the sole saved-entry tree surface. Posting with no Reply target creates
  a root edge and brings that new root into view; tapping a placement does not
  push a second saved-entry surface. Every visible placement instead exposes
  **Reply** from its context menu so a continuation can be authored in place.
  When the selected vault is shared — owned or joined as a participant — the
  navigation toolbar also
  shows the same system `SWCollaborationView` control used by the vault picker,
  keeping collaboration management available from Home. The control registers
  the runtime's fetched zone-wide `CKShare` and appears once that share is
  loaded; it disappears after sharing is stopped and
  the runtime refreshes.

  Creation lives in one Book-style glass input bar inset at the bottom of Home.
  Its center is a multiline **Write something** text field that grows from one
  to five lines. Each Vault owns one root draft plus an isolated Reply draft for
  each parent placement selected during the current view lifetime. Choosing
  **Reply** switches to the draft keyed by that Vault and parent edge without
  erasing or retargeting the root draft or another parent's draft. Cancelling
  Reply returns to the root draft, and selecting another placement restores that
  parent's existing draft.

  Reply destination is explicit state, independent of navigation and visibility.
  The composer holds a detached target value containing the Vault id, parent
  `CardEdge.edgeID`, owning root edge id, and a small display snapshot; it never
  retains a live SwiftData model as the posting destination. While Reply is
  active, a persistent target strip above the input identifies the destination
  and provides **Cancel Reply**. If the selected parent becomes deleted,
  unresolved, or otherwise inactive, posting is disabled and the strip explains
  that the destination is unavailable. Missing targets never fall back to a new
  root post. Choosing Reply also requests focus for the composer after the
  context menu closes.

  When the untouched text field
  receives a complete HTTP(S) URL as its first input update, that same draft
  switches to Link and uses the existing Link preview. A URL typed incrementally
  or added after any existing text remains part of the Text entry.
  The trailing glass up-arrow posts that entry and is enabled only when the
  current content is persistable: text and Todo must contain non-whitespace
  content, a link must resolve to a valid HTTP(S) URL, and capture-backed kinds
  must contain their completed payload. A newly authored Todo is incomplete.
  Command-Return invokes the same post action. On
  iOS, starting a drag on the saved-entry scroller dismisses the inline text
  keyboard, including when the active vault has too few entries to scroll. On
  macOS, the bar is centered and capped at `720pt`; Command-Shift-V opens Vaults
  and Command-comma opens Settings.

  The complete input bar is also a drop destination while the root composer is
  active; selecting a Reply target disables drop handling. Root-mode drop accepts
  text, HTTP(S) URLs, still images, movies, audio, and individual generic files.
  A dropped text value that is entirely one detected HTTP(S) URL becomes a Link
  root, while prose that merely
  contains a URL remains Text. This does not change the first-input-only rule for
  typing or pasting into the text field.

  After SwiftUI materializes the accepted values for one drop action, Tinycurve
  validates each value and automatically posts it as an independent root in the
  order SwiftUI supplied it. The drop path never replaces, clears, or reuses the
  unpublished composer draft. It freezes the selected writable Vault when the
  action begins, and every accepted value remains a root regardless of later
  Reply selection. Each accepted item uses its own `createThread(cards:)`
  transaction; one invalid item or failed write does not roll back sibling roots
  that already succeeded. Provider-owned files are copied while their transfer
  URLs are valid, classified as Photo, Video, Audio, or File, and removed from
  app-temporary storage after that item's write attempt. Directories and
  Live Photo pair reconstruction are not supported by this drop surface.

  After at least one root succeeds, Home refreshes once, reloads the Latest Note
  widget once, and scrolls toward the last successful root. Complete success
  uses the normal **Posted to Journal** confirmation. Partial success shows a
  persistent warning that the remaining items were posted; complete failure
  shows a persistent drop-specific failure and explicitly says the current
  input was not changed.

  While the input is the untouched empty text entry, the leading `+` opens a
  standard SwiftUI `Menu` containing Todo, Link, Camera, Photos, Bauhaus,
  Doodle, Voice, and feature-flagged Suggestions. Text needs no menu item because
  it is entered directly in the bar. Choosing Todo keeps the compact composer,
  adds an incomplete-circle affordance, and focuses a multiline Todo field. The
  system owns menu placement, interaction,
  accessibility, and dismissal. Once the input is no longer the untouched text
  placeholder — including while it is in Link mode — the `+` becomes an
  `xmark`; choosing it requires destructive confirmation before the unpublished
  entry is discarded. Changing vaults also requires confirmation while any root
  or Reply draft for the current Vault contains an unpublished entry.

  Quick Capture requests always return to Home and create a root card. They use
  the same draft-preservation rule. With every root and Reply draft empty,
  they open the focused text editor, camera, voice recorder, doodle
  canvas, or system Suggestions picker directly. If unpublished input exists at
  the current Vault's root or Reply drafts, Journal asks before discarding them;
  cancelling consumes the system request and leaves every draft unchanged.

  Todo, Link, Camera, Photos, Bauhaus, Doodle, Voice, and Suggestions reuse that
  same single entry rather than appending another draft. Link capture uses URL-keyboard
  input and normalizes values such as `example.com` to HTTPS. Camera writes a
  `CapturedPhoto`; Photos uses the system picker and imports still images,
  videos, or Live Photos while preserving the paired Live Photo resources. A
  failed library import leaves the current input in place and shows a persistent
  failure notification. Doodle and Bauhaus present native sheets at the large
  detent and stream non-empty vector/grid changes into the entry; clearing the
  canvas or grid restores the empty text input. Voice writes the completed
  `AudioRecording`, including its measured waveform history. After a non-text
  capture completes, the input bar shows a
  preview rendered from the actual authored payload. Valid Links use a large
  native rich-link surface; Photo, Video, Live Photo, Doodle, and Bauhaus use a
  large square visual; Audio uses a wide horizontal waveform. These expanded
  surfaces occupy only the center column between the leading discard and
  trailing post buttons, and do not repeat the kind as visible text. An
  incomplete Link and the remaining non-text kinds keep the compact preview and
  modality label. Tapping a preview opens the matching detail editor without
  allowing the persisted content type to be switched;
  imported video, Live Photo, and Suggestion details are preview-only, while
  supported authored formats remain editable.

  The Suggestions action presents Apple's Journaling Suggestions picker. One
  picker selection becomes one aggregate Suggestion entry containing the returned
  title, date interval, and all resolved top-level elements; it does not fan the
  elements out into a creation-time chain. The authored payload is stored as JSON
  rather than in the persisted body field. When source files are locally available, photos,
  videos, Live Photo components, posters, artwork, and icons are copied into
  additional suggestion media resources and referenced from that payload.
  Previews use the first element as the primary subject and summarize remaining
  elements. The resolver supports Contacts, Event Posters, Generic Media, Live
  Photos, Locations, Location Groups, Motion Activity, Photos, Podcasts,
  Reflections, Songs, State of Mind, Videos, Workouts, Workout Details, and
  Workout Groups; transient SwiftUI decoration values such as suggestion
  gradients/colors are not persisted.

  When the Settings **Attach Location** preference is enabled, the composer asks
  for a one-shot coordinate only after the entry becomes persistable and attaches
  it to that unpublished entry. Disabling the preference or losing location
  authorization clears the in-progress coordinate; posting still succeeds
  without location when no coordinate is available. The saved-entry list shows a
  compact, wide map header whenever the selected vault contains located entries.
  This noninteractive header stays zoomed around the most recently created
  located entry and uses the same native pin clustering as the full map, so
  nearby or overlapping entries appear as a count marker rather than duplicate
  pins while the normal content grid remains directly below it. Tapping the
  header pushes an interactive **Map** screen
  whose initial camera frames every located entry in the selected vault. Nearby
  or overlapping pins automatically group into a count marker and separate into
  individual pins as the user zooms in. The up-arrow freezes one save snapshot,
  including its posting destination, and converts it into one
  `VaultContentStore.CardDraft`. With no Reply target it calls
  `createThread(cards:)` with that single value, persists one root `CardEdge`,
  refreshes the root-only Latest Note widget, and scrolls Home toward the new
  root. With Reply active it revalidates the detached target against the same
  Vault and calls `appendCard(_:to:)` with the selected parent edge; a missing
  or inactive parent fails instead of falling back to `createThread(cards:)`.
  Continuation posting does not refresh the root-only widget.

  A successful Reply issues one Home reveal request containing the owning root
  edge and appended edge. Home first scrolls to the root anchor so its lazy day
  section and subtree are materialized, then scrolls vertically to the appended
  node once that placement participates in layout. If the current content-type
  filter excludes the owning root, Home consumes the request when the new edge
  reaches the live query without scrolling, so a later filter change cannot
  cause a delayed jump. Success clears only the draft and Reply selection that
  still match the frozen save destination; a target or draft selected while the
  write was in flight remains untouched. Root posting follows the same frozen
  match rule for its draft. Failure retains the Reply target and its draft. The
  Photo, Video, and Live Photo write paths generate or carry a bounded
  thumbnail; Doodle, Bauhaus, and Suggestion retain authored payloads, with
  Suggestion media copied alongside its JSON when available.

  Successful posting shows a transient **Posted to Journal** notification with
  success haptics. If posting fails, the unpublished entry stays in the input bar
  and a persistent **Could not post** notification states that the input is still
  present, with failure haptics. Notifications appear as an app-wide overlay at
  the top of the screen, then fade, blur, and scale in place with a slight bounce
  instead of sliding from an edge. Each press of the up-arrow posts exactly one
  card: either a root or one direct child of the explicit Reply target. It never
  accumulates several unpublished entries into one creation-time chain.
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
  active (`deletedAt == nil`) `CardEdge` rows with SwiftData, follows the `Card` / `Attachment` /
  `AttachmentResource` relationships, and builds a cycle-safe tree projection
  from every resolved active placement. Home selects root placements
  (`parentEdgeID == nil`) as grouping anchors. Roots are grouped into
  local-calendar day sections by the root card's own creation date and read as
  one vertical stream; adding a continuation does not move the root to another
  day or create another Home item. Each root item contains the root and its full
  active descendant subtree. This initial implementation projects and renders
  descendants eagerly. Any placement that is not reachable from a valid root —
  including an unresolved placement, an orphan and its descendants, or a
  rootless cyclic component — is omitted. Recursive projection also stops at a
  repeated edge defensively. Tree identity is the placement's stable
  `CardEdge.edgeID`, never the authored card id.

  Making Home the sole tree surface and selecting Reply targets are UI-state
  changes only. They add no SwiftData schema, migration, CloudKit record, or sync
  field; root creation continues to use `createThread(cards:)`, and Reply
  continues to use the existing `CardEdge.parentEdgeID` relationship through
  `appendCard(_:to:)`.

  Home's toolbar provides a single-selection
  content-type filter with **All Entries** plus every supported user-visible
  `Card.Kind`; unknown content
  remains available through All Entries but is not a selectable filter. The
  selection is transient UI state and changes only when the user chooses an
  option, so vault changes, Reply selection, and posting do not reset it. The
  filter applies only when selecting Home roots and location-map pins. Once a
  root is selected, descendants remain unfiltered so the thread stays intact.
  If a non-empty vault has no roots of the selected type, Home shows a filtered
  empty state with **Show All Entries**. Posting a matching root keeps the filter
  and scrolls that root into view. Posting a root outside the current filter still
  succeeds and remains hidden; its pending Home scroll is cleared as soon as the
  root reaches the live query so a later filter change cannot cause a delayed
  jump.

  Every tree node reuses the same current saved-entry card presentation at every
  depth and fills the finite width proposed by the vertical tree surface.
  Descendants reserve one fixed leading marker gutter, while the marker count
  communicates their semantic depth without progressively narrowing deeper
  cards. This does not substitute a thumbnail style, suppress video behavior,
  or introduce a continuation count or other summary label. The tree has no
  horizontal scroll surface: Home composes maps, day headers, and complete root
  trees in its one existing vertical stream. Tree nodes remain placements in
  Home; their tap surface does not push another saved-entry destination.
  Reply reveal uses that same Home scroll surface and only the owning root can
  consume its two-stage request.
  Pull-to-refresh asks the vault runtime to import fresh CloudKit changes;
  the old toolbar reload icon is not shown in the normal list surface. Link
  content uses iOS's LinkPresentation preview in Home groups, fetching
  metadata at display time and caching it in a dedicated device-local SwiftData
  store under the app's Caches directory for up to seven days. The cache is not
  synced or backed up, is bounded to 200 entries / 50 MiB, and may be purged by
  the operating system. Cache access is serialized synchronously on MainActor;
  only remote metadata fetching remains asynchronous.
  The natural-height Link placement owns a finite height; native metadata updates
  invalidate intrinsic layout only when the metadata object actually changes.
  Media placeholders reserve the same aspect-ratio geometry as their loaded
  content, so a row keeps one height from its first layout pass through its
  poster, still image, and inline player. Home trees present
  authored content without a common shape, rounded clipping, stroke, or fixed
  height. Text uses its natural height. In Home, Text detects HTTP(S) URL ranges
  at display time and exposes them as underlined native links without changing
  the Card kind or persisted body;
  Photo, Video, and Live Photo use the persisted pixel dimensions (falling back
  to decoded media dimensions) and aspect-fit the complete image without crop.
  Doodle saves its authored canvas size alongside its JSON and reserves that
  geometry too. Doodles without recorded dimensions use the canonical 4:5
  authored ratio, so idle, loading, and rendered states keep one cell height.
  Tree nodes read the full vault media file using the same card presentation at
  every depth. Video previews
  play as muted inline loops when the media file is local, while keeping the app
  audio session mixed with other audio so external music or podcasts continue.
  Doodle and Bauhaus previews decode the authored JSON attachment file and render
  it with their SwiftUI renderers. When a media file is not local yet, the UI
  shows a modality placeholder; when sync writes the file and bumps the resource
  revision, SwiftData observation re-runs the affected content load. Audio cells
  summarize their recording's persisted measured levels into the available bars;
  recordings created before waveform persistence retain the decorative fallback.
  Their play control starts and pauses that recording in place and returns to its
  idle state as soon as the sound stops, whether the recording reached its end,
  another card took playback over, or the system interrupted it.
  Todo entries
  show an explicit completion control on every visible Home tree node. Completing
  or reopening a Todo changes `completedAt` and `updatedAt` atomically with the
  Card outbox mutation, without moving it in the chronological stream or tree.
  Editing its text preserves the saved completion state; share artifacts and
  widget surfaces render that state without offering a mutation control. Every
  visible tree node's context menu exposes Reply, Share, Edit, and Delete. Reply
  selects the explicit composer target described above; it does not navigate or
  mutate storage by itself. On iPhone and iPad, each individual tree node also
  exposes Reply through a physical-right `SwipeCell` gesture. The row gesture
  begins only when horizontal movement is dominant, so vertical or equal-axis
  movement remains owned by Home's vertical scroll. The row continues to
  rubber-band to the right within `0...50pt`. Crossing `+44pt`
  reveals the same 44-point leading circular Reply affordance and produces
  impact feedback. A normally ended gesture past that threshold selects the same
  explicit Reply target exactly once; ending below the threshold, cancellation,
  or failure restores the row without selecting Reply. Dragging the same row to
  the left instead slides it aside to disclose that entry's capture time, shown
  behind the trailing edge as the time of day above its abbreviated month and
  day. The left range stops exactly at the width of that disclosure, and the
  gesture carries no trigger in that direction: releasing the row always
  restores it without mutating anything. Native macOS renders the
  cell content unchanged, without installing that swipe interaction; context-menu
  and accessibility Reply remain available. Saved entries can be shared from
  that menu. The share
  action opens a preview sheet backed
  by a detached `EntryShareSnapshot`, renders the actual temporary PNG artifact
  as ordinary Home-cell content centered inside a vertical `ShareFrame`, and
  does not add kind/date or Tinycurve/location chrome. The frame is authored at
  360 x 640pt and uniformly rasterized at 3x for the default 1080 x 1920px
  output. For Doodle or Bauhaus entries with authored replay data, the preview
  also offers a generated mp4 whose vector replay is aspect-fitted into the same
  centered 32pt-inset bounds before handing the selected file to the system
  activity sheet. Saved entries can be edited from any visible tree node's
  context menu.
  Editing rehydrates the saved entry into
  `EntryDraftEditor`, requires the full media file for media content, and saves
  back through `VaultContentStore.updateCard(cardID:with:)`; thumbnails are not
  used as lossy edit sources. Saved entries can also be deleted from any visible
  tree node's context menu. Deletion is confirmed
  first, then writes through `VaultContentStore.deleteCardEdge(edgeID:)`. The
  selected edge subtree leaves normal queries immediately, while its live
  SwiftData models and local media stay retained and attached. CloudKit record
  deletes are enqueued immediately in the same transaction. Incoming CardEdge
  or placed-Card deletion applies the same local logical deletion; edit-only
  attachment/resource replacement may still physically remove obsolete local
  rows and files. Deleting a Reply target makes that detached target unavailable;
  the view remains on Home and its draft is neither discarded nor posted as a
  root.
- **`SettingsView`** — an optional development-only **Profile** destination, an
  **Accent Color** picker, an **Appearance** picker, a **Location**
  toggle for automatic location attachment, a **Storage** section with **Cloud
  Storage** estimates, a **Widgets** section with an **Add Widgets** guide,
  optional Debug-only **Vault Runtime** and Lab links, and About actions.
  Its **Notifications** row reflects the app-scoped system authorization state:
  **Enable** is available while not determined, **On** means alert-enabled,
  **Quiet** means provisional authorization, and an alert-disabled state directs
  the user to settings instead of issuing another request. iOS opens Apple's
  documented notification Settings URL; native macOS opens System Settings and
  explains `Notifications > Tinycurve` without relying on a private URL scheme.
  The same controller is explicitly injected into the native macOS Settings
  scene. Choosing **Not Now** from a contextual primer suppresses automatic
  re-presentation for the rest of that install.
  Settings is a grouped `Form`, but every cell background opts into the
  neutral `MuColor` secondary container because SwiftUI form rows do not inherit
  the app surface automatically. Selecting an accent writes
  `JournalDefaults.accentColorID` (animated) and triggers selection haptic feedback.
  When `TINYCURVE_PROFILE_IMAGE` is enabled, **Profile** loads the current user's
  optional public profile image from the CloudKit system `Users` record. On
  iPhone, iPad, and native macOS, the user can
  choose one image with the system Photos picker, drag and zoom inside a circular
  crop preview, and explicitly **Save** a 512 x 512 square JPEG. Save updates only
  the `profileImage` field with changed-keys semantics; **Remove Photo** clears
  that field without deleting the system user record. Selection and crop cancel
  never upload data. The first editor deliberately does not expose rotation or
  normalize EXIF orientation metadata. Loading, saving, refresh, general failure,
  and unavailable-iCloud states remain visible in the Profile screen. The image
  is Tinycurve-wide public identity that may later identify authors in
  collaborative features; it is not stored per Vault and is not journal content.
  The Appearance segmented picker writes
  `JournalDefaults.appearancePreferenceID`; **System** follows the device
  setting, while **Light** and **Dark** request a fixed scene color scheme for
  Journal and update the neutral palette immediately. The **Attach Location**
  toggle writes `JournalDefaults.shouldAttachLocationToNewCards`; it defaults on,
  and when disabled new draft entries are saved without location metadata. **Cloud
  Storage** opens a Settings detail screen that estimates Journal's CloudKit
  payload from active local vault rows (logically deleted retained rows are
  excluded): owned vaults are grouped as data that counts
  toward the user's iCloud quota, participant vaults are grouped as shared data
  charged to the originating owner, and breakdowns show text/link body bytes,
  media file bytes, thumbnail bytes, record counts, and media kind totals. It is
  labeled as an estimate because CloudKit does not expose exact iCloud usage or
  server overhead to the app. **Add Widgets** opens a Settings detail screen with
  an illustrated header and
  step-by-step instructions for adding Tinycurve to the Home Screen, Lock Screen
  below the clock, and StandBy. The guide frames the widget as showing the
  latest entry in a chosen vault.
  On iPhone and iPad, the toolbar action continues to present
  `SettingsScreen` as the existing dismissible sheet, including its zoom
  transition from Creation. The sheet uses form presentation sizing so SwiftUI
  chooses a compact settings width on iPad while retaining the platform-native
  sheet treatment on iPhone. On native macOS, `TinycurveApp` declares a SwiftUI
  `Settings` scene instead: the application menu and Command-comma open one
  system-managed Settings window, toolbar actions target that same window, and
  the window's standard close control replaces an in-content dismiss button.
  The independent scene receives the same `JournalVaultRuntime`, theme, and
  appearance preference as the main window, plus `JournalUserProfile` only when
  its development flag is enabled. Its size remains stable while navigating
  between Settings pages rather than resizing around each detail.
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
acceptance, still needs physical-device or signed native-macOS verification.

For a debuggable Production check, select the shared `Tinycurve Production`
scheme and run it on a physical iOS device or as the signed native macOS app.
The scheme uses `DebugProduction`, so `DEBUG`, debugger attachment, and debug
optimization remain enabled while the signed CloudKit entitlement is
`Production`. The iOS Simulator only accesses CloudKit Development and cannot
validate this path. `Tinycurve Production` uses the shipping bundle ID and full
sync engine, so it can create, update, share, and delete real production data.
`TINYCURVE_PROFILE_IMAGE` is deliberately absent from this configuration despite
its debug semantics, so the unfinished public-profile UI and CloudKit client are
not compiled into the app root or Settings scene for Production checks.

Todo completion adds the optional `Card.completedAt` date field. Existing or
older records that omit it import as incomplete. Before release, verify that the
field exists with the Date type in the Development schema and deploy the updated
schema to Production together with the rest of the vault record types.

Recorded audio adds the optional `AttachmentResource.waveformData` Bytes field.
Existing records that omit it remain valid and render the legacy fallback. Before
release, verify the field in the Development schema and deploy it to Production;
otherwise Production uploads cannot carry the waveform metadata to other devices.

**Before sync works on real devices:** create/let Xcode auto-create the
`iCloud.app.muukii.journal` container, verify the vault record types in the
CloudKit Console during Development, test private and shared vaults on two
physical devices, then **Deploy Schema to Production** before any
`DebugProduction`, Release, or TestFlight build (`Tinycurve Production`,
TestFlight, and App Store use the Production environment).

---

## Documentation Policy

Update this file when a change affects what a user can do or see in the Journal
app — new/changed/removed capture components, model changes, screens, themes,
entitlements, or platform behavior. Skip it for pure refactors, style changes, or
bug fixes that restore already-documented behavior.

This app-local spec covers Journal's product behavior. The repo-root
`docs/SPECIFICATION.md` covers cross-app distribution (Ad Hoc OTA, App Store
Connect) and is a separate concern.
