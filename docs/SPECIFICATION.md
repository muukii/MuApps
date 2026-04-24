# Verse (YouTubeSubtitle) - Product Specification

## Overview

Verse (project name: YouTubeSubtitle) is a SwiftUI app for iOS and macOS that lets users watch YouTube videos with synced subtitles, navigation tools, and on-device language assistance.

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
- Auto-fetch YouTube transcripts on load (language auto-detected by YouTube)
- Cached subtitles stored locally per history item
- On-device transcription (SpeechAnalyzer) when captions are unavailable
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
- Edit mode: drag handles for reordering history items (Manual sort mode only)
- Context menu: Add to Playlist

### URL Input Sheet (URLInputSheet)
- URL field with live metadata preview
- "Open Video" primary action

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

### Interactions
- Auto-tracking stops on manual scroll or selection
- Swipe actions for translate/explain
- Context menus for subtitle actions and step mode
- Sheets use medium/large detents on iOS

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
- Expanded iPad/macOS layout optimizations
