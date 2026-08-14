# MuApps - Distribution Specification

## Ad Hoc OTA Install Page
- Pushes to the `main` branch run the Ad Hoc workflow automatically; manual runs can still publish all apps or a selected app from `main`.
- The workflow exports Ad Hoc IPAs for Verse, Journal/Tinycurve, PhotosOrganizer, AmbientLight, Färg, PolyReader, and VoiceRecorder.
- Deployable apps are listed in `.github/adhoc-apps.json` with their distribution name, project path, scheme, bundle identifier, IPA filename, and manifest filename.
- Each selected app runs an isolated `Archive <App>` → `Deploy <App>` job chain. The app matrix disables fail-fast, so an archive or export failure skips only that app's deploy without cancelling sibling app chains.
- Each successful app deploy replaces only that app's assets in the single `adhoc-latest` GitHub release. The release therefore represents the latest successfully published main build per app, rather than one atomic all-app snapshot.
- GitHub Pages serves `docs/install.html` as the shared install page for each app's latest successfully published `main` Ad Hoc build.
- Each app has its own install action backed by an `itms-services` manifest in the `adhoc-latest` GitHub release.
- Installs require a registered iPhone included in the Apple Developer Ad Hoc provisioning profile.

## App Store Connect Deployment
- The App Store Connect workflow manages deploys for Verse, Journal/Tinycurve, AmbientLight, and Färg.
- Pushes to the `main` branch automatically upload apps marked with `deploy_on_main`; currently Verse, Journal/Tinycurve, and Färg.
- Manual workflow runs can choose Verse, Journal, AmbientLight, Färg, or all configured apps.
- Deployable apps are listed in `.github/appstore-apps.json` with their scheme, project path, Xcode version, macOS runner, and optional `deploy_on_main` flag.
- If `all` is selected, apps whose project path does not exist on the current branch are skipped with a notice; selecting a missing app directly fails the run with a clear error.
- The shared deploy workflow installs Tuist dependencies, generates the workspace, archives the selected scheme, signs the archived app and nested extensions with discovered entitlements, then exports and uploads to App Store Connect using the repository App Store Connect API key secrets.

## Local Build Coverage
- The pull request build workflow has separate matrices for release-targeted apps under `Apps/` and active experiments under `Experiments/`.
- Active experiments are CodexPet, ColorPlayground, HearAugment, HelloWorld, SafariReactor, and TabLab.
- Experiments are not included in Ad Hoc OTA publishing or App Store Connect deployment.
- Archived experiments remain under `Experiments/` but are omitted from the root workspace and CI matrices.

---

# CodexPet - Product Specification

## Overview

CodexPet is an experimental SwiftUI app for previewing Codex Desktop custom pet sprite atlases on iPhone and iPad.

## Core Features

### 1. Bundled Codex Pets
- Includes the local Mofu Monkey and Mofu Monkey Dot Codex pet atlases as app-bundled PNG spritesheets.
- Uses the Codex custom pet atlas contract: 8 columns, 9 animation rows, and 192 x 208 pixel cells.
- Provides a segmented picker for switching between the bundled soft plush and pixel-art variants.

### 2. Sprite Animation Playback
- Plays all Codex pet states: idle, running-right, running-left, waving, jumping, failed, waiting, running, and review.
- Uses a SwiftUI timeline to select frames from the current animation row.
- Applies smooth interpolation for the plush pet and nearest-neighbor interpolation for the pixel-art pet.

### 3. Playground Motion
- Shows the pet in a full-screen stage with state controls at the bottom.
- Moves the pet horizontally for directional running states.
- Adds vertical motion for jumping and subtle bobbing for stationary states.
- Includes a playback speed slider from 0.25x to 2.0x.

### 4. Widgets
- Provides a WidgetKit extension named Codex Pet.
- Supports Home Screen small and medium widgets, plus Lock Screen circular and rectangular accessory widgets.
- Lets people configure the widget's bundled pet and pose from the widget edit sheet.
- Renders a static representative frame for the selected pose because WidgetKit widgets are snapshot-driven rather than continuous animation surfaces.

### 5. Web App
- Provides a static web app under `Experiments/CodexPet/Web/`.
- Uses the same bundled Mofu Monkey and Mofu Monkey Dot sprite atlases as PNG assets.
- Animates the pet by updating CSS sprite background positions from the 8 x 9 Codex pet atlas.
- Detects transparent atlas cells in a canvas pass and excludes blank frames while keeping each visible frame's full 192 x 208 cell registration.
- Supports pet switching, pose switching, and playback speed control in the browser.
- Includes a web app manifest and app icons so the page can be installed as a standalone browser app where supported.

## Current Constraints
- The first version bundles known local pet assets instead of importing arbitrary pet packages from Files.
- The app does not read Codex Desktop's <code>~/.codex/pets</code> directory at runtime.
- The app is local/simulator-focused and is not configured for Ad Hoc OTA or App Store Connect deployment yet.
- The widget does not play continuous pet animation; it displays a stable frame from the selected atlas row.
- The web app ships as a static artifact and has been manually deployed to Cloudflare Pages with Wrangler; automated Pages deployment is not configured yet.

---

# Safari Reactor - Product Specification

## Overview

Safari Reactor is an iPhone/iPad container app for a Safari Web Extension that experiments with Language Reactor-style learning tools on Netflix playback pages.

## Core Features

### 1. Safari Web Extension
- Injects into `https://www.netflix.com/watch/*`.
- Also injects into `localhost` and `127.0.0.1` pages for local development with a mock player.
- Displays a floating overlay above the page without entering full screen.
- Detects visible subtitle text from Netflix-like timed text containers or a development `[data-sr-subtitle]` element, including multi-line subtitles split across separate DOM nodes.
- Captures detected subtitle cues into an in-memory transcript list with timestamps.
- Allows tapping a transcript cue to seek back to that cue.
- Provides first-milestone playback actions:
  - Back 5 seconds
  - Play/pause
  - Repeat from the start time of the current detected subtitle
  - Cycle playback speed through 0.75x, 1.0x, 1.25x, and 1.5x
- Keeps the overlay enabled by default and does not expose a toolbar popup in the first milestone, avoiding Safari's extension popover path on iPad while playback behavior is being validated.

### 2. Container App
- Shows setup instructions for enabling the extension in Settings > Safari > Extensions.
- Explains that the first milestone targets the normal Safari player, not full-screen playback.
- Summarizes the current target page, milestone, and default overlay behavior.

### 3. Development Mock
- Includes `Experiments/SafariReactor/Development/mock-player.html` as a local Netflix-like fixture.
- The mock page reuses the production content script and stylesheet so overlay, subtitle detection, and playback controls can be developed before real Netflix/Safari verification.

## Constraints
- The extension does not download, export, or persist Netflix subtitle files.
- Transcript capture is currently derived from observed page subtitles; direct Netflix subtitle payload extraction is a later milestone.
- The first milestone keeps Netflix-specific behavior in the content script selector adapter and keeps learning overlay behavior site-independent.
- Codex Desktop's in-app browser may not play Netflix DRM content, so real Netflix playback verification must happen in Safari on device or desktop Safari.

---

# Verse (YouTubeSubtitle) - Product Specification

## Overview

Verse (project name: YouTubeSubtitle) is a SwiftUI app for iPhone and iPad that lets users play YouTube videos or imported audio and video files with synced subtitles, navigation tools, and on-device language assistance.

- On iPhone, the app interface supports portrait orientation only; landscape rotation is not supported.

### Target Users
- Language learners (English, Japanese, and other subtitle languages)
- Students watching educational content
- Viewers who prefer reading along with video

## Core Features

### 1. Video Playback

#### 1.1 Video Sources
- Play YouTube videos by URL (watch, youtu.be, shorts, etc.)
- In-app YouTube browser with "Open with Subtitles" action
- Import one or more audio or video files from Files (multi-select supported)
  - Validate that each selected file contains playable audio or video
  - Copy each imported file into app-managed Documents storage for persistent access
  - Each imported file becomes its own history item; a batch is inserted at the top sorted alphabetically by filename (locale-aware), regardless of selection order
  - Importing a single file opens it in the local player; importing multiple files stays on the Home list
  - Files that fail validation or copying are skipped; one alert lists each failed file name with its reason while the remaining files still import
  - Show dedicated waveform artwork for audio-only files
- Local playback when a video has been downloaded (feature-flagged)
- Background audio for local media (downloaded videos and imported audio/video files):
  - Audio continues when the app moves to the background or the screen is locked
  - Local playback becomes the device's primary audio (takes over other apps' audio); leaving the player releases the audio session so other apps can resume
  - Lock Screen / Control Center shows Now Playing info (title, author, thumbnail artwork; waveform-less audio imports show as audio type)
  - Remote commands: play/pause, skip backward/forward 10 seconds, and scrubbing from the system player
  - YouTube streaming is excluded: it pauses when the app leaves the foreground and mixes with other apps' audio while in the foreground

#### 1.2 Playback Controls
- Play/pause, time display, and scrubber
- Playback speed: 0.5x to 2.0x (0.25 increments)
- Seek buttons with configurable modes:
  - Seconds jump (3, 5, 10, 15, 30)
  - Subtitle-based jump (current / next)
- Step Mode:
  - Toggle via play/pause context menu
  - Auto-pauses at each subtitle cue end
  - Outline play/pause icons in step mode, filled icons in normal mode
- Loop control:
  - Loop entire video, or A-B section if repeat points are set
- A-B repeat:
  - Set A/B from subtitle menu or repeat setup UI
  - Ring slider controls for precise A/B times
- Collapse/expand player to focus on subtitles
- Resume playback from last saved position
  - Auto-saves position every 30 seconds during playback
  - Saves when app goes to background
  - Saves when leaving the player screen

### 2. Subtitles

#### 2.1 Retrieval and Caching
- Cached subtitles stored locally per history item
- Auto-generate subtitles on load with on-device transcription when enabled and no suitable cached subtitles exist; a transcript that has been manually chunk-edited is never replaced automatically
- On-device transcription (SpeechAnalyzer) can enhance cached/imported subtitles with word timing data
- Manual subtitle import from files (SRT, VTT, SBV, CSV, LRC, TTML)

#### 2.2 Display
- List of cues with timestamps
- Top and bottom edge fades mask scrollable subtitle content when more content is available offscreen
- Current cue highlight
- Word-level highlight when timing data is available (transcription)

#### 2.3 Navigation and Tracking
- Tap timestamp to seek
- Auto-scroll tracking enabled by default
- Tracking toggle (arrow-up-left icon):
  - Auto-disables on manual scroll or text selection
  - Tap to re-enable and jump to current cue
- Jumping from search results or the bookmark list re-enables tracking so the subtitle display follows the new position

#### 2.4 Subtitle Actions
- Swipe actions:
  - Translate, Bookmark (leading)
  - Ask ChatGPT (trailing) — opens the default browser with the explanation prompt pre-filled (surrounding cues included as context)
- Context menu per cue:
  - Bookmark / Remove Bookmark
  - Copy
  - Ask ChatGPT
  - Translate
  - Set as A (start) / B (end)
  - Merge with Previous / Merge with Next under Edit Chunk; the unavailable direction is disabled on the first or last cue
- Text selection shows custom items in the system edit menu:
  - "Split Here" splits at the start of an internal selection, with the selected word beginning the new lower cue
  - "Ask ChatGPT" sends the selected text with the cue as context
- Chunk edits are persisted with the history item and immediately become the cue sequence used by current-cue tracking, subtitle seeking, Step Mode, search, and export
  - Merging spans the upper cue's start through the lower cue's end and retains word timings only when both cues contain timing data
  - Splitting a timed cue uses the selected word's exact start time and preserves timings on both halves
  - Splitting a cue without word timings estimates the boundary proportionally from the selected text position within the cue
  - Existing cue identities remain stable where possible; SRT export always emits sequential numbers from the edited display order
  - A manually edited transcript is marked in its cached JSON; explicitly starting transcription shows a destructive-replacement confirmation

#### 2.5 Subtitle Management
- Export subtitles in selected format (SRT, VTT, SBV, CSV, LRC, TTML)
- Share YouTube URL from player menu
- If local file exists:
  - Switch playback source (YouTube / Local)
  - Transcribe audio to subtitles
  - Delete local video

#### 2.6 Subtitle Bookmarks
- Bookmark a subtitle cue from the row's context menu or the leading swipe action; both toggle (re-invoking removes the bookmark)
- Bookmarked rows show a small filled bookmark icon on the leading seek area
- Bookmarks store a snapshot of the cue's text and time range, so they survive transcript regeneration; a row is considered bookmarked when the cue's time range contains the bookmarked range's midpoint (robust to re-transcription shifting cue timings)
- After a chunk edit, each bookmark follows the resulting cue that contains its prior temporal midpoint; bookmarks that collapse onto the same merged cue are deduplicated
- Bookmark list (bookmark icon in the player toolbar) opens a medium/large-detent sheet:
  - Rows show a timestamp pill and the bookmarked text, sorted by time
  - Tap to seek playback to the cue's start and dismiss the sheet
  - Swipe to delete
  - Empty state explains how to add bookmarks
- Bookmarks are stored per video (SwiftData) and deleted together with the history item

#### 2.7 Subtitle Search
- Search sheet (magnifying-glass icon in the player toolbar; disabled while no subtitles are loaded)
- Custom search field at the top, auto-focused on open, with a clear (x) button
- Locale-aware, case- and diacritic-insensitive full-text matching over the current transcript's cues
- Result rows show a timestamp pill and the cue text with every query match highlighted (bold, accent color)
- Section header shows the match count ("N Matches")
- Tap a result to close the sheet and seek playback to the cue's start (tracking re-enabled)
- The query is retained while the player stays open, so reopening the sheet restores the previous results
- Empty states: prompt before typing; "no results" for unmatched queries; scrolling results dismisses the keyboard

### 3. AI and Language Tools
- Word/phrase explanations are delegated to ChatGPT; the app builds the prompt and opens it externally
  - The prompt asks for a translation and a detailed explanation of meaning, usage, and nuances
  - Opens in the default browser, so the ChatGPT app takes over when it is installed and handles the link
  - There is no in-app explanation UI and no on-device generation
- AI Response Language (Settings > Language): System / English / Japanese
  - The language the ChatGPT prompt asks for answers in
  - System (default) follows the device language
- System Translation for subtitle lines and words

### 4. History and Library

#### 4.1 Watch History
- Auto-saved on open
- YouTube entries are deduplicated by video ID (most recent kept); each imported file creates a separate entry
- No item limit
- Local storage (SwiftData)
- List display: thumbnail, title, author (when available), relative time
- Playback progress bar: red bar on thumbnail bottom showing watch progress
- Last played time tracking: automatically updated whenever playback position is saved
- Sort options (via menu in top-left toolbar):
  - **Manual**: drag & drop custom ordering in edit mode
  - **Last Played**: sorted by most recently played videos (videos never played fall back to date added)
  - **Date Added**: sorted by when video was added to history (newest first)
- Edit mode:
  - Uses multi-selection controls instead of leading minus deletion controls
  - Supports Select All / Deselect All, adding the selection to a playlist, and confirmed batch deletion
  - Adding to a playlist keeps Edit mode and the selection active for another batch action
  - Leaving Edit mode clears the transient selection
  - In Manual sort, selected rows can also be reordered with drag handles
- Manual ordering:
  - Uses lexicographic string ordering for efficient reordering
  - New items are added to the top of the list
- Actions: tap to open, swipe to delete, batch Add to Playlist / delete in Edit mode, clear all (in Settings)

#### 4.2 Playlists
- First-class feature surfaced as a horizontal "Playlists" shelf at the top of the Home screen
  - Playlist cards show an orange list icon, name (up to 2 lines), and video count
  - Trailing dashed "New Playlist" card opens the create sheet
  - Tap a card to open the playlist; long-press for a context menu with Delete Playlist
- Create, rename, delete playlists
- Add one or more videos from history; existing playlist entries are skipped
  - Edit mode exposes a visible Add to Playlist action for the current selection
  - A selection-aware context menu acts on one row in normal mode or all selected rows in Edit mode
  - The playlist picker shows the selection count and marks playlists that already contain the complete selection
  - Newly added videos preserve their current History display order
- Reorder and remove entries
- Video entries show playback progress bar on thumbnails
- Open videos from playlist view; the player pushes onto the same navigation stack (back returns to the playlist, then Home)

### 5. Downloads and Offline Playback (Feature-Flagged)
- Download progressive MP4 streams with quality selection
- Progress indicators in history and player
- Local playback with source switching
- Delete downloaded files
- UI hidden in Release builds; downloads still used internally for transcription

### 6. External Integrations
- In-app YouTube browser (with iOS sign-in flow)
- Ask ChatGPT opens the default browser (or the ChatGPT app via universal link)

### 7. Live Transcription (Experimental)
- Real-time microphone transcription (iOS 26+ physical device)
- Text selection shows an "Ask ChatGPT" item in the system edit menu
- Shareable session transcript
- Session history with detail view and export

## Screen Layout

### Home (HomeView)
- Empty state with "Try Demo Video" (shown only when both history and playlists are empty)
- "Playlists" section: horizontal shelf of playlist cards plus a "New Playlist" card
- "History" section: list with thumbnails, metadata, and playback progress bars (hidden while history is empty)
- Toolbar: Sort menu (Manual/Last Played/Date Added), Edit, Settings; Edit mode replaces Settings with Select All / Deselect All
- Bottom bar: Add Media menu (Paste YouTube URL / Import Audio or Video), Browse YouTube; Edit mode replaces it with the selected count, Add to Playlist, and batch Delete actions
- Navigation uses a single stack on all devices; selecting a history item pushes the player, selecting a playlist card pushes the playlist (no split view / detail pane)
- Edit mode: History rows use selection controls with no leading minus icons; Manual sort additionally shows drag handles
- Context menu: selection-aware Add to Playlist (one History row or the current multi-selection), Delete Playlist (playlist cards)

### URL Input Sheet (URLInputSheet)
- URL field with live metadata preview
- "Open Video" primary action
- On iPad, sheet content is centered in a narrower form-width layout for easier scanning

### YouTube Browser (YouTubeWebView)
- Web view with back/forward/reload
- iOS sign-in action
- "Open with Subtitles" overlay on watch/shorts pages

### Player (PlayerView)
- Video player at top (YouTube or imported/downloaded local video); imported audio shows waveform artwork
- Collapsible player area
- Subtitle list with tracking toggle
- Playback controls: scrubber, speed, seek, loop, A-B setup
- Toolbar: subtitle search, bookmarks, subtitle management, on-device transcribe, download (if enabled)
- On iPad, the player, subtitle reader, and controls stay centered within a readable-width column

### Settings (SettingsView)
- Language: AI Response Language picker (System / English / Japanese)
- Data: Clear History (with confirmation dialog)
- Experimental: Live Transcription
- Debug-only feature flags

## UI/UX Specifications

### Visuals
- Accent color used for current subtitle and word highlights
- Tracking toggle: filled icon when enabled, outlined when disabled
- Subtitle row timestamp pill for quick seek
- The last-opened history row uses a tinted rounded highlight

### Interactions
- Auto-tracking stops on manual scroll or selection
- Swipe actions for translate / Ask ChatGPT
- Context menus for subtitle actions and step mode
- Sheets use medium/large detents on iOS
- Selecting a history item pushes the player onto the navigation stack with a zoom transition from the tapped thumbnail

## Data and Storage
- SwiftData local storage only (no cloud sync)
- Cached subtitles stored in history items
- Subtitle bookmarks stored per history item (cascade-deleted with the item)
- Downloaded videos and imported audio/video files stored in Documents
- Imported Files URLs are used only while copying; persistent playback uses the app-managed copy
- Subtitle import/export via Files

## Limitations
- Channel/author names may be unavailable (metadata limitation)
- No subtitle language selector yet
- Download UI disabled in Release builds
- On-device and live transcription require iOS 26+ physical device
- Explanations require leaving the app for ChatGPT (browser or ChatGPT app); there is no offline or in-app explanation

## Future Enhancements
- CloudKit sync for history and playlists
- Subtitle language selection and multi-language support
- Subtitle filtering
- Improved channel/author metadata
- Dedicated subtitle library management
- Additional iPad and macOS large-screen layout refinements

---

# HearAugment - Product Specification

## Overview

HearAugment is a SwiftUI iPhone and iPad audio AR prototype inspired by real-time environmental sound filtering apps. It listens through the device microphone, processes the live signal with editable effect chains, and plays the result through the current headphone route. Headphones and AirPods are playback-only routes; their microphones are not used for capture.

## Core Features

### 1. Live Listening
- Checks microphone permission on launch and asks for access only when the user starts live listening for the first time.
- Shows explicit pending, requesting, denied, and granted microphone states. If access is denied, the primary Start control changes to **Open Settings** and the app re-checks permission when it becomes active again after the user returns from Settings.
- Uses `AVAudioEngine` for audio-session hosting, microphone tap input, and output.
- Microphone frames are passed through an Objective-C++ bridge into a C++ low-level float ring buffer and rendered by `AVAudioSourceNode`.
- The render callback runs a custom C++ sample-by-sample serial effect chain instead of standard EQ, delay, reverb, or dynamics Audio Units.
- The C++ ring buffer uses a single-producer/single-consumer atomic index design so the steady-state render path avoids mutex locking.
- The C++ input ring keeps about 2.5 seconds of microphone frames as underrun protection; this capacity is separate from the low-latency input tap buffer.
- The source node renders a stereo float format so mono microphone input can feed stereo processors such as panning, ping-pong delay, stereo reverb, and width effects.
- Shows current listening state, elapsed listening time, selected chain, enabled effect count, and any audio-session errors.
- Continues live listening when the app moves to the background or the screen is locked, declared via the `audio` `UIBackgroundModes` capability so the engine and microphone remain active.
- Recovers from audio-session interruptions (phone calls, Siri, alarms, other audio apps grabbing the session): when the interruption ends and the system grants resumption, listening restarts automatically if the user had not manually stopped it.
- Requires a headphone-style output route before live listening starts. If AirPods, headphones, USB audio, or another accepted headphone route disappears during listening, the app stops the engine and asks the user to reconnect headphones before starting again.
- Below the Start/Stop control, a **Bypass** toggle disables every effect at once for an instant dry reference, and a **Hold to Compare** button momentarily flips the bypass state while pressed and restores it on release. Both controls are only active while listening.

### 2. Serial Effect Chains
- Provides built-in chain presets such as Clean Leveler, Focus Stack, Wide Room, Tape Accelerator, Reverse Bloom, Mod Lab, Lo-Fi Tunnel, Motion Field, Divergence Bloom, Gravity Tail, and Tape Riser.
- Each preset is a serial list of effect nodes. Users can add nodes, remove nodes, enable or disable nodes, and reorder nodes by dragging the row handle to change the processing order.
- Each effect row is collapsed by default and shows a drag handle, icon, name, **Solo** button, **Mute** toggle, and an expand chevron. Tapping the row title or the chevron expands the row to reveal Amount / Parameter A / Parameter B sliders and a Remove button. Expansion state is per-session and is cleared when a preset is selected.
- The Solo headphones button on each row temporarily isolates one or more effects: while any effects are soloed, only those effects are audible regardless of their Mute state. A "Solo: N / Clear" banner appears at the top of the chain panel while solo is active, and selecting a preset or removing a soloed node clears the solo state. Solo state is not persisted.
- The effect library includes high pass, low pass, tilt EQ, presence EQ, compressor, noise gate, soft clip, wave folder, bit crusher, tremolo, ring mod, panner, auto pan, vibrato, chorus, flanger, phaser, slap delay, accelerating delay, tape riser delay, stereo delay, ping-pong delay, reverse grains, room reverb, stereo reverb, shimmer, comb resonator, space widener, binaural beat, long bloom, and converge bloom.
- Reverb is implemented in C++ with feedback comb filters and all-pass diffusion. Stereo reverb uses separate left/right tanks with cross-feed and width processing.
- Long Bloom uses a longer C++ feedback-comb and all-pass tank to make tails continue for several seconds before decaying.
- Converge Bloom opens the tail into a wide stereo side field while residual energy is strong, then progressively collapses it back toward the center as the tail fades.
- Accelerating Delay uses a geometric multi-tap echo pattern where later taps are closer together, making repeats feel faster over time.
- Tape Riser Delay behaves like a tape delay with discrete long-spaced echoes whose repeat interval multiplies down toward a short target; each repeat raises its delay-line read speed above realtime, so the echoes accelerate and audibly rise in pitch as they converge.
- Binaural Beat adds independent left and right sine carriers whose frequencies are separated by the Beat parameter. It is a stereo/headphone effect: Amount controls tone level, Carrier controls the center frequency, and Beat controls the left/right frequency difference.
- Reverse uses double-buffered C++ reverse grains and can smear the reversed signal with an additional delay line.
- Chain and parameter changes apply immediately while listening.
- The Chain Intensity slider scales every node's amount before the chain is sent to C++.
- Output slider controls the engine's main mixer output level.

### 3. Buffer Control
- The Buffer panel lets users choose the requested microphone tap buffer size before starting live listening.
- Available buffer sizes are 128, 256, 512, and 1024 frames.
- 256 frames is the default balanced setting, matching the original input tap behavior.
- Larger buffers request longer `AVAudioSession` I/O durations and can improve stability for heavy chains at the cost of additional latency.
- The selected buffer size is stored in `UserDefaults` and reused on the next launch.
- Buffer size changes are disabled while listening is active because the input tap and audio session must be recreated to apply them.

### 4. Custom Presets
- The Effect Chain panel includes a preset name field and Save button.
- Saving stores the current chain as a custom preset in `UserDefaults`.
- Custom presets appear alongside built-in presets and can be selected later.
- Custom presets can be deleted from the preset card context menu.

### 5. Audio Route
- Uses the on-device built-in microphone as the capture device. AirPods, Bluetooth HFP microphones, wired headset microphones, USB microphones, and other external inputs are not selected for HearAugment capture.
- Shows the device microphone as the selected microphone while listening is stopped.
- Shows selected input, active input route, captured channel layout (Mono / Stereo / N ch), and output route.
- Enables Bluetooth A2DP output routing on the audio session but does not enable Bluetooth HFP input, so supported AirPods/headphones can be used for playback without becoming the microphone.
- For the device microphone, the app requests a stereo capture path: it picks a data source whose supported polar patterns include `.stereo`, sets that polar pattern, sets the input orientation to portrait, and asks the session for two preferred input channels. Devices that do not support stereo capture silently fall back to whatever channel layout they natively provide; the engine handles a mono return by mirroring the single channel to both stereo output channels.
- Warns when headphones or AirPods are not connected to reduce feedback risk.

### 6. Hearing Safety
- The UI states that users should start with low device volume.
- The app is presented as a creative audio AR prototype, not a medical hearing device.

## Limitations
- No recording, session history, or cloud sync yet.
- The chain can contain up to 16 editable nodes in the UI and the C++ engine clamps incoming chains to 24 nodes.
- Final input/output routing is controlled by iOS and connected hardware.
- The app is not intended to diagnose, treat, or compensate for hearing loss.

---

# PolyReader - Product Specification

## Overview

PolyReader is a minimal SwiftUI reading app for iPhone and iPad that lets users paste text, save it locally, and read it one sentence at a time with automatic sentence advancement.

## Core Features

### Text Library
- Users add reading material by pasting or typing text into an in-app editor sheet.
- Titles are optional; when omitted, the app uses the first non-empty line as the title.
- Saved texts appear in a library list with a short body preview and sentence progress.
- Users can delete saved texts from the library.

### Sentence Reader
- The reader displays one sentence at a time in a large centered reading layout.
- Text is segmented with sentence-level Natural Language tokenization, with punctuation-based fallback for texts the tokenizer cannot segment.
- The reader opens paused at the saved sentence position.
- Controls include play/pause, previous sentence, next sentence, and restart from the first sentence.
- Progress is shown as current sentence count, total sentence count, and a progress bar.

### Automatic Advancement
- Playback advances through sentences automatically.
- Reading speed is controlled by a WPM slider from 80 to 400 WPM, defaulting to 180 WPM.
- Each sentence display duration is estimated from word count, with a minimum display time of 1.2 seconds.
- Playback stops at the final sentence.

## Data and Storage
- SwiftData stores saved texts locally.
- Stored fields include title, body, creation date, update date, and current sentence index.
- The current sentence position is saved as the user advances through the text.
- No cloud sync, file import, dictionary, translation, vocabulary, or AI assistance is included in the MVP.

---

# VoiceRecorder - Product Specification

## Overview

VoiceRecorder is a simple SwiftUI utility app for continuously streaming the selected microphone input through the current audio output with an adjustable delay and temporary live transcription. The app does not save clips, keep a recording history, or provide playback of captured files.

## Core Features

### 1. Microphone Selection
- Lists available audio input devices from `AVAudioSession`, including the device microphone, headset microphones, USB inputs, and Bluetooth HFP inputs such as AirPods when available.
- The selected input is used for live streaming.
- The app shows the selected input, active input route, and current output route.

### 2. Live Streaming
- Streams the selected microphone input through an `AVAudioEngine` graph.
- Centers the live monitor path to a mono stream before output, so single-sided or multi-channel microphone input is heard from both ears.
- No audio file is written to temporary or persistent storage.
- The streaming screen uses a single-page console layout with a large central start/stop button, elapsed streaming time, and a live bar-style input level meter.
- Streaming stops automatically when the app moves to the background.

### 3. Adjustable Delay
- Provides delayed live monitoring using `AVAudioUnitDelay`.
- Delay is adjustable from 0.15 seconds to 2.0 seconds.
- Delay changes are applied to the active live stream.
- The delayed signal is sent to the current headphone output route; the UI warns the user when headphones or AirPods are not connected to avoid feedback.

### 4. Temporary Live Transcription
- Uses Apple's SpeechAnalyzer/SpeechTranscriber APIs to transcribe the live microphone stream when speech recognition is available on the device.
- Transcribed text is displayed only as temporary on-screen captions and is not persisted.
- Caption items expire automatically after a short lifetime, so older text disappears first.
- Expiring captions visually dissolve with a Metal shader that breaks the text into drifting smoke-like particles before removal.

## Screen Layout
- The app presents one primary page centered around a studio-console surface.
- The page header shows the app name and a concise live-streaming tagline.
- The console shows current status, output route, streaming controls, temporary live captions, microphone input details, and delay controls in a single vertical flow separated by dividers.
- Error, permission, and headphone-feedback warnings appear as compact tinted banners above or inside the console.

## Limitations
- The app does not retain recordings and does not offer playback history.
- Live transcription depends on SpeechAnalyzer availability, supported locale, and installed speech assets.
- AirPods microphone selection depends on iOS exposing the Bluetooth HFP input route.
- iOS controls the final output route; the app displays the route and encourages connecting headphones before streaming.

---

# PhotosOrganizer - Product Specification

## Overview

PhotosOrganizer is a SwiftUI utility app for iPhone and iPad that scans the user's photo library, surfaces image file sizes, and converts selected images to HEIF or AVIF to reduce storage usage.

## Core Features

### Photo Library Access
- Requests read/write Photo Library permission on launch.
- Supports full and limited library authorization.
- Shows a denied-access state when Photos permission is unavailable.

### Photo Browser
- Displays user-library image assets in a three-column grid.
- Loads thumbnail previews with network access enabled for iCloud-backed photos.
- Shows file-size badges after resource sizes are loaded.
- Sorts images by creation date or file size from the toolbar menu.

### Photo Detail
- Shows a large preview for the selected image.
- Displays metadata including file size, dimensions, filename, format identifier, creation date, photo subtype, and location when available.
- Presents conversion controls from the detail screen.

### Conversion
- Converts selected images to HEIF or AVIF.
- Offers a quality slider from 10% to 85%.
- Previews converted size, saved bytes, and reduction percentage before saving.
- Saves converted images back to Photos while preserving creation date, location, and favorite state.

## Platform and Integrations
- Target platforms: iPhone and iPad.
- Minimum deployment target: iOS 26.2.
- Uses PhotoKit for library access and writes.
- Uses ImageIO for HEIF encoding and `avif.swift` for AVIF encoding.

---

# AmbientLight (Calm Light) - Product Specification

## Overview

AmbientLight is a SwiftUI iPhone and iPad app, displayed to users as Calm Light, that turns the device screen into a full-screen HDR ambient light with animated organic color patterns and bounded light-painting scenes.

## Core Features

### Ambient Display
- Shows each ambient scene edge-to-edge, with bounded light-painting scenes returning to a pure-black canvas outside their emitted light.
- Uses SwiftUI stitchable Metal shaders for GPU-rendered effects.
- Enables high dynamic range rendering where supported by the display.
- Hides the status bar and forces dark appearance for an uninterrupted light surface.
- Disables the device idle timer while the app is active so the light remains on; idle timer behavior is restored when the app becomes inactive or enters the background.

### Scenes
- Includes selectable ambient scenes:
  - Solar Field
  - Amber Fog
  - Aurora
  - Color Tide
  - Firelight
  - Moon Smoke
- Solar Field renders a red-to-gold circular light field over a fixed pure-black background. Its exterior bloom has a finite falloff and returns fully to black away from the light.
- Solar Field keeps its outer silhouette stable while its red core wanders slightly, broad internal convection reshapes the red-to-gold layers, and a localized golden flare slowly travels around the rim.
- The orbiting flare grows and recedes over independent slow periods, locally widening the rim and brightening its finite bloom without disturbing the pure-black background.
- Solar Field keeps the saturated red center primarily within SDR and lets the rim reach the display's currently available EDR headroom at the crest of its pulse. The animation pauses while the scene is not selected, the app is inactive, or the Light Timer has turned the light off.
- Solar Field remains a true circle across portrait and landscape layouts, using the shorter screen dimension as its scale.
- New installations open on Solar Field by default.
- The last selected scene is stored locally and restored on next launch.

### Interaction
- A fresh installation opens with a single live-scene introduction explaining
  that people can choose a scene, shape its light, and set a timer. Completing
  the introduction reveals the production controls over the same scene rather
  than navigating through a separate tutorial carousel.
- During normal viewing, the interface disappears completely. Tapping the
  display reveals the current scene's ordered position, user-facing name and
  description, plus a bottom **Scenes / Adjust / Timer** Light Dock. The dock
  hides again after a short inactive period or when the display is tapped.
- **Scenes** enters the full-size scene switcher. Long-pressing anywhere remains
  a shortcut to the same mode instead of being its only discoverable entrance.
- In switcher mode, horizontal scrolling is enabled and each pattern is shown with side margins for browsing. The centered scene is the active selection, and one gesture advances at most one scene even on iPad. Opening or closing the switcher transforms the same live scene without changing its scroll position.
- Select **Done** to return from switcher mode to the full-screen selected scene.
- **Adjust** reveals a temporary matrix control overlay for pattern-specific
  two-axis adjustment. The overlay states what each scene's gesture changes and
  exposes **Fine Tune** and **Done** actions.
- For Solar Field, the matrix control moves the center of the projected light horizontally and vertically.
- The matrix control hides automatically after a short delay, remains visible
  while the user is dragging it, and can open a native sheet containing the
  scene's complete slider and color controls.

### Light Timer
- **Timer** presents 15-minute, 30-minute, and one-hour session choices.
- A running timer can be replaced or stopped from the same sheet.
- When the timer reaches zero, the rendered scene is covered by a black resting
  screen and Calm Light releases its idle-timer override so the device can sleep.
  Tapping **Light off** wakes the scene and restores normal keep-awake behavior.

## Platform and Integrations
- Target platforms: iPhone and iPad, with native full-screen layouts on both.
- Minimum deployment target follows the MuApps shared iOS app target.
- Bundle identifier: `app.muukii.ambientlight`.
- User-facing display name: Calm Light.

---

# Tone - Product Specification

## Overview

Tone is a SwiftUI iPhone app for English shadowing practice. Users import audio and subtitles, play subtitle-aligned chunks, record their own voice over the source audio, and review vocabulary-style cards.

## Core Features

### Shadowing Library
- Stores imported learning items in SwiftData.
- Supports local audio/subtitle import and YouTube-based import/download flows.
- Shows a library of audio items with title editing, deletion, and tag-based organization.
- Includes bundled preview audio and subtitle content for simulator/demo use.

### Player
- Plays audio with synchronized subtitle chunks.
- Supports current-chunk tracking, pinning ranges, and reviewing pinned sections.
- Provides playback controls for play/pause, seeking, speed changes, looping, and A-B style focused practice.
- Offers configurable subtitle/chunk font size from settings.

### Recording Practice
- Records the user's microphone while source audio is playing.
- Replays recordings aligned with the main audio timeline for pronunciation comparison.
- Uses a dedicated audio session manager to switch between playback and recording modes.
- Cleans up temporary recording files on app launch.

### Transcription
- Transcribes imported audio with Apple's on-device SpeechAnalyzer/Speech Recognition APIs.
- Downloads and prepares Apple speech recognition assets when required by the system.
- Supports background transcription progress tracking and optional user notifications.
- Includes an OpenAI transcription service path for API-key-backed workflows.
- Registers the `app.muukii.tone.transcription` background task identifier.

### Vocabulary and Cards
- Provides Anki-style vocabulary review screens.
- Imports Anki JSON data.
- Shows card stacks, card detail/edit views, tag detail screens, and generated example sentence support through the OpenAI service.

### Live Activity
- Includes a WidgetKit Live Activity extension for player controls/status.
- Uses the `group.app.muukii.tone` app group for sharing activity state between the app and extension.

## Screen Layout

### Main Tab View
- Library tab for imported audio items and transcription progress.
- Player tab/full-player presentation for active shadowing playback.
- Anki/vocabulary areas for card review and imported vocabulary content.
- Settings screen for background transcription notifications and subtitle font size.

### Import Views
- Audio import supports selecting local audio and subtitle files.
- Audio and subtitle import flow creates new learning items.
- YouTube import/download screens provide a URL-based path into the same shadowing library.

## Data and Storage
- SwiftData stores items, segments, pins, and tags using the current V3 schema.
- Audio files are stored locally in the app container.
- CloudKit entitlements and container identifiers are configured, but the current SwiftData configuration uses local storage.
- Preview content is included as development assets for simulator use.

## Platform and Integrations
- Target platform: iPhone.
- Minimum deployment target follows the MuApps shared iOS app target.
- Uses microphone access, background audio/processing, Live Activities, CloudKit entitlement configuration, and app groups.
