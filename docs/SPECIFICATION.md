# MuApps - Distribution Specification

## Ad Hoc OTA Install Page
- Pushes to the `main` branch run the Ad Hoc workflow automatically; manual runs can still publish all apps or a selected app from `main`.
- The workflow exports Ad Hoc IPAs for Verse, Tone, PhotosOrganizer, HearAugment, PolyReader, VoiceRecorder, and HelloWorld.
- Builds are published to the single `adhoc-latest` GitHub release so the release list does not grow per branch.
- GitHub Pages serves `docs/install.html` as the shared install page for the latest `main` Ad Hoc builds.
- Each app has its own install action backed by an `itms-services` manifest in the `adhoc-latest` GitHub release.
- Installs require a registered iPhone included in the Apple Developer Ad Hoc provisioning profile.

---

# Verse (YouTubeSubtitle) - Product Specification

## Overview

Verse (project name: YouTubeSubtitle) is a SwiftUI app for iPhone and iPad that lets users watch YouTube videos with synced subtitles, navigation tools, and on-device language assistance.

### Target Users
- Language learners (English, Japanese, and other subtitle languages)
- Students watching educational content
- Viewers who prefer reading along with video

## Core Features

### 1. Video Playback

#### 1.1 Video Sources
- Play YouTube videos by URL (watch, youtu.be, shorts, etc.)
- In-app YouTube browser with "Open with Subtitles" action
- Deep link and Shortcuts support for opening YouTube URLs
- Local playback when a video has been downloaded (feature-flagged)

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
- Auto-generate subtitles on load with on-device transcription when enabled and no suitable cached subtitles exist
- On-device transcription (SpeechAnalyzer) can enhance cached/imported subtitles with word timing data
- Manual subtitle import from files (SRT, VTT, SBV, CSV, LRC, TTML)

#### 2.2 Display
- List of cues with timestamps
- Current cue highlight
- Word-level highlight when timing data is available (transcription)

#### 2.3 Navigation and Tracking
- Tap timestamp to seek
- Auto-scroll tracking enabled by default
- Tracking toggle (arrow-up-left icon):
  - Auto-disables on manual scroll or text selection
  - Tap to re-enable and jump to current cue

#### 2.4 Subtitle Actions
- Swipe actions:
  - Translate (leading)
  - Explain (trailing)
- Context menu per cue:
  - Copy
  - Explain
  - Translate
  - Set as A (start) / B (end)
- Word tap opens Word Detail (translate, explain, add to vocabulary, copy)
- Text selection supports Explain with context

#### 2.5 Subtitle Management
- Export subtitles in selected format (SRT, VTT, SBV, CSV, LRC, TTML)
- Share YouTube URL from player menu
- If local file exists:
  - Switch playback source (YouTube / Local)
  - Transcribe audio to subtitles
  - Delete local video

### 3. AI and Language Tools
- Word/phrase explanations using Apple Intelligence
  - On-device processing with structured generation for:
    - Translation (in user's preferred language)
    - Detailed explanation of meaning, usage, and nuances
    - Phrase analysis: breakdown of context sentence into meaningful phrases with grammatical roles
    - Idiom detection: identifies idioms/fixed expressions with meaning and origin
  - "Ask Gemini" button opens Gemini with the same prompt (in-app browser on iOS)
  - "Share Prompt" option to share the explanation prompt
- Vocabulary auto-fill using Apple Intelligence
  - Structured generation for meaning, examples, and notes
  - Part of speech detection
- System Translation for subtitle lines and words

### 4. History and Library

#### 4.1 Watch History
- Auto-saved on open
- Deduplicated by video ID (most recent kept)
- No item limit
- Local storage (SwiftData)
- List display: thumbnail, title, author (when available), relative time
- Playback progress bar: red bar on thumbnail bottom showing watch progress
- Last played time tracking: automatically updated whenever playback position is saved
- Sort options (via menu in top-left toolbar):
  - **Manual**: drag & drop custom ordering in edit mode
  - **Last Played**: sorted by most recently played videos (videos never played fall back to date added)
  - **Date Added**: sorted by when video was added to history (newest first)
- Manual reordering (Manual sort mode only):
  - Edit button in top-left toolbar toggles edit mode (only visible in Manual sort mode)
  - Drag & drop support for custom ordering
  - Uses lexicographic string ordering for efficient reordering
  - New items are added to the top of the list
- Actions: tap to open, swipe to delete, clear all (in Settings)

#### 4.2 Playlists (Experimental)
- Create, rename, delete playlists
- Add videos from history (context menu)
- Reorder and remove entries
- Video entries show playback progress bar on thumbnails
- Open videos from playlist view

#### 4.3 Vocabulary (Experimental)
- Manual vocabulary list (term, meaning, part of speech, examples, notes)
- Add vocabulary from Word Detail: tap "Add to Vocabulary" button to open vocabulary edit sheet with term pre-filled
- AI auto-fill: tap ✨ button after entering a term to auto-generate meaning, part of speech, example sentences with translations, and notes using Apple Intelligence (structured response)
- Learning state badges (New, Learning, Reviewing, Mastered)
- Search, add, edit, delete

### 5. Downloads and Offline Playback (Feature-Flagged)
- Download progressive MP4 streams with quality selection
- Progress indicators in history and player
- Local playback with source switching
- Delete downloaded files
- UI hidden in Release builds; downloads still used internally for transcription

### 6. External Integrations
- Siri and Shortcuts: "Open YouTube Video" intent
- Deep link handling for YouTube URLs
- In-app YouTube browser (with iOS sign-in flow)

### 7. Live Transcription (Experimental)
- Real-time microphone transcription (iOS 26+ physical device)
- Word tap for translation/explanation
- Shareable session transcript
- Session history with detail view and export

## Screen Layout

### Home (HomeView)
- Empty state with "Try Demo Video"
- History list with thumbnails, metadata, and playback progress bars
- Toolbar: Sort menu (Manual/Last Played/Date Added), Edit (for reordering in Manual mode only), Settings
- Bottom bar: Paste URL, Browse YouTube
- iPad layout uses a split view with a persistent history sidebar and a dedicated detail pane for playback; the detail pane shows a "Select a Video" prompt until the user chooses an item
- Edit mode: drag handles for reordering history items (Manual sort mode only)
- Context menu: Add to Playlist

### URL Input Sheet (URLInputSheet)
- URL field with live metadata preview
- "Open Video" primary action
- On iPad, sheet content is centered in a narrower form-width layout for easier scanning

### YouTube Browser (YouTubeWebView)
- Web view with back/forward/reload
- iOS sign-in action
- "Open with Subtitles" overlay on watch/shorts pages

### Player (PlayerView)
- Video player at top (YouTube or Local)
- Collapsible player area
- Subtitle list with tracking toggle
- Playback controls: scrubber, speed, seek, loop, A-B setup
- Toolbar: subtitle management, on-device transcribe, download (if enabled)
- On iPad, the player, subtitle reader, and controls stay centered within a readable-width column

### Settings (SettingsView)
- Apple Intelligence status for Word Explanations
- Apple Intelligence status for Vocabulary Auto-Fill
- Siri and Shortcuts tips
- Data: Clear History (with confirmation dialog)
- Experimental: Vocabulary, Playlists, Live Transcription
- Debug-only feature flags

## UI/UX Specifications

### Visuals
- Accent color used for current subtitle and word highlights
- Tracking toggle: filled icon when enabled, outlined when disabled
- Subtitle row timestamp pill for quick seek
- Selected videos in the iPad sidebar use a tinted rounded highlight

### Interactions
- Auto-tracking stops on manual scroll or selection
- Swipe actions for translate/explain
- Context menus for subtitle actions and step mode
- Sheets use medium/large detents on iOS
- On iPad, selecting a history item updates the detail pane in place instead of pushing a full-screen navigation stack

## Data and Storage
- SwiftData local storage only (no cloud sync)
- Cached subtitles stored in history items
- Downloaded videos stored in Documents
- Subtitle import/export via Files

## Limitations
- Channel/author names may be unavailable (metadata limitation)
- No subtitle language selector yet
- Download UI disabled in Release builds
- On-device and live transcription require iOS 26+ physical device
- Apple Intelligence features (word explanations, vocabulary auto-fill) require supported device and enabled system setting

## Future Enhancements
- CloudKit sync for history, playlists, and vocabulary
- Subtitle language selection and multi-language support
- Subtitle search and filtering
- Improved channel/author metadata
- Dedicated subtitle library management
- Additional iPad and macOS large-screen layout refinements

---

# HearAugment - Product Specification

## Overview

HearAugment is a SwiftUI iPhone and iPad audio AR prototype inspired by real-time environmental sound filtering apps. It listens through the device microphone, processes the live signal with editable effect chains, and plays the result through the current headphone route.

## Core Features

### 1. Live Listening
- Requests microphone permission on launch.
- Uses `AVAudioEngine` for audio-session hosting, microphone tap input, and output.
- Microphone frames are passed through an Objective-C++ bridge into a C++ low-level float ring buffer and rendered by `AVAudioSourceNode`.
- The render callback runs a custom C++ sample-by-sample serial effect chain instead of standard EQ, delay, reverb, or dynamics Audio Units.
- The C++ ring buffer uses a single-producer/single-consumer atomic index design so the steady-state render path avoids mutex locking.
- The C++ input ring keeps about 2.5 seconds of microphone frames as underrun protection; this capacity is separate from the low-latency input tap buffer.
- The source node renders a stereo float format so mono microphone input can feed stereo processors such as panning, ping-pong delay, stereo reverb, and width effects.
- Shows current listening state, elapsed listening time, selected chain, enabled effect count, and any audio-session errors.
- Stops live listening automatically when the app enters the background.

### 2. Serial Effect Chains
- Provides built-in chain presets such as Clean Leveler, Focus Stack, Wide Room, Tape Accelerator, Reverse Bloom, Mod Lab, Lo-Fi Tunnel, Motion Field, Divergence Bloom, Gravity Tail, and Tape Riser.
- Each preset is a serial list of effect nodes. Users can add nodes, remove nodes, enable or disable nodes, and move nodes up or down to change the processing order.
- The effect library includes high pass, low pass, tilt EQ, presence EQ, compressor, noise gate, soft clip, wave folder, bit crusher, tremolo, ring mod, panner, auto pan, vibrato, chorus, flanger, phaser, slap delay, accelerating delay, tape riser delay, ping-pong delay, reverse grains, room reverb, stereo reverb, shimmer, comb resonator, space widener, long bloom, and converge bloom.
- Reverb is implemented in C++ with feedback comb filters and all-pass diffusion. Stereo reverb uses separate left/right tanks with cross-feed and width processing.
- Long Bloom uses a longer C++ feedback-comb and all-pass tank to make tails continue for several seconds before decaying.
- Converge Bloom opens the tail into a wide stereo side field while residual energy is strong, then progressively collapses it back toward the center as the tail fades.
- Accelerating Delay uses a geometric multi-tap echo pattern where later taps are closer together, making repeats feel faster over time.
- Tape Riser Delay behaves like a tape delay with discrete long-spaced echoes whose repeat interval multiplies down toward a short target; each repeat raises its delay-line read speed above realtime, so the echoes accelerate and audibly rise in pitch as they converge.
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
- Lists available audio input devices from `AVAudioSession`.
- Allows input selection while listening is stopped.
- Shows selected input, active input route, and output route.
- Warns when headphones or AirPods are not connected to reduce feedback risk.

### 6. Hearing Safety
- The UI states that users should start with low device volume.
- The app is presented as a creative audio AR prototype, not a medical hearing device.

## Limitations
- No recording, session history, cloud sync, or background listening yet.
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

VoiceRecorder is a simple SwiftUI utility app for recording one voice clip at a time, replaying it immediately, and optionally monitoring the live microphone signal through headphones with an adjustable delay.

## Core Features

### 1. Microphone Selection
- Lists available audio input devices from `AVAudioSession`, including the device microphone, headset microphones, USB inputs, and Bluetooth HFP inputs such as AirPods when available.
- The selected input is used for normal recording.
- The app shows the selected input, active input route, and current output route.

### 2. One-Clip Recording
- Records to a temporary AAC `.m4a` file.
- Starting a new recording replaces the previous clip.
- No recording history or persistent library is shown.
- The recording screen shows elapsed time and a live input level meter.

### 3. Immediate Playback
- The latest clip can be played as soon as recording stops.
- Playback shows the latest clip duration and a progress indicator.
- Playback uses the current system audio output route.

### 4. Delay Monitor
- Provides a live delayed monitoring mode using `AVAudioEngine` and `AVAudioUnitDelay`.
- Delay is adjustable from 0.15 seconds to 2.0 seconds.
- Monitor mode forces the input to Device Microphone.
- The delayed signal is sent to the current headphone output route; the UI warns the user when headphones or AirPods are not connected to avoid feedback.

## Limitations
- Only the latest temporary recording is retained.
- AirPods microphone selection depends on iOS exposing the Bluetooth HFP input route.
- iOS controls the final output route; the app displays the route and encourages connecting headphones before monitor mode.

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
