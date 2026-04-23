//
//  PlayerModel.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/12/04.
//

import Algorithms
import Foundation
import SwiftUI

// MARK: - SeekSeconds (shared)

enum SeekSeconds: Double, CaseIterable, Codable {
  case s3 = 3
  case s5 = 5
  case s10 = 10
  case s15 = 15
  case s30 = 30

  var displayName: String {
    "\(Int(rawValue)) seconds"
  }
}

// MARK: - BackwardSeekMode

enum BackwardSeekMode: Hashable, Codable {
  case seconds(SeekSeconds)
  case subtitle(Subtitle)

  enum Subtitle: String, CaseIterable, Codable {
    case current = "current"
    case skip = "skip"

    var displayName: String {
      switch self {
      case .current: return "Subtitle"
      case .skip: return "Subtitle (Skip)"
      }
    }
  }

  var displayName: String {
    switch self {
    case .seconds(let s): return s.displayName
    case .subtitle(let s): return s.displayName
    }
  }

  var interval: Double? {
    switch self {
    case .seconds(let s): return s.rawValue
    case .subtitle: return nil
    }
  }

  static var allCases: [BackwardSeekMode] {
    SeekSeconds.allCases.map { .seconds($0) } + Subtitle.allCases.map { .subtitle($0) }
  }
}

// MARK: - BackwardSeekMode + RawRepresentable

extension BackwardSeekMode: RawRepresentable {
  init?(rawValue: String) {
    let parts = rawValue.split(separator: ":")
    guard parts.count == 2 else { return nil }

    let type = String(parts[0])
    let value = String(parts[1])

    switch type {
    case "seconds":
      guard let doubleValue = Double(value),
            let seconds = SeekSeconds(rawValue: doubleValue) else { return nil }
      self = .seconds(seconds)
    case "subtitle":
      guard let subtitle = Subtitle(rawValue: value) else { return nil }
      self = .subtitle(subtitle)
    default:
      return nil
    }
  }

  var rawValue: String {
    switch self {
    case .seconds(let s):
      return "seconds:\(Int(s.rawValue))"
    case .subtitle(let s):
      return "subtitle:\(s.rawValue)"
    }
  }
}

// MARK: - ForwardSeekMode

enum ForwardSeekMode: Hashable, Codable {
  case seconds(SeekSeconds)
  case subtitle  // Forward only has one subtitle mode (next)

  var displayName: String {
    switch self {
    case .seconds(let s): return s.displayName
    case .subtitle: return "Subtitle"
    }
  }

  var interval: Double? {
    switch self {
    case .seconds(let s): return s.rawValue
    case .subtitle: return nil
    }
  }

  static var allCases: [ForwardSeekMode] {
    SeekSeconds.allCases.map { .seconds($0) } + [.subtitle]
  }
}

// MARK: - ForwardSeekMode + RawRepresentable

extension ForwardSeekMode: RawRepresentable {
  init?(rawValue: String) {
    let parts = rawValue.split(separator: ":")
    guard parts.count == 2 else { return nil }

    let type = String(parts[0])
    let value = String(parts[1])

    switch type {
    case "seconds":
      guard let doubleValue = Double(value),
            let seconds = SeekSeconds(rawValue: doubleValue) else { return nil }
      self = .seconds(seconds)
    case "subtitle":
      self = .subtitle
    default:
      return nil
    }
  }

  var rawValue: String {
    switch self {
    case .seconds(let s):
      return "seconds:\(Int(s.rawValue))"
    case .subtitle:
      return "subtitle:next"
    }
  }
}

// MARK: - CurrentTime

/// Observable wrapper for current playback time.
/// By wrapping the time value in an @Observable class, only views that actually
/// read `.value` will re-render when the time updates (every ~100ms).
/// Intermediate views that just pass the reference won't re-render.
@Observable
final class CurrentTime: @unchecked Sendable {
  var value: Double = 0
}

// MARK: - PlayerModel

/// Observable model for PlayerView that holds frequently updated playback state
/// and manages the PlayerController.
/// This separates mutable playback state and control logic from the view to improve
/// performance and enable better state management.
@Observable
@MainActor
final class PlayerModel {

  // MARK: - Playback State (updated every 500ms)

  /// Current playback position in seconds.
  /// Wrapped in @Observable class to prevent intermediate view re-renders.
  let currentTime = CurrentTime()

  /// Whether the video is currently playing
  private(set) var isPlaying: Bool = false

  // MARK: - Video Info

  /// Total duration of the video in seconds
  var duration: Double = 0

  // MARK: - Playback Rate

  /// Current playback speed (1.0 = normal)
  var playbackRate: Double = 1.0

  // MARK: - Slider/Seeking State

  /// Whether the user is currently dragging the slider
  var isDraggingSlider: Bool = false

  /// The time position while dragging
  var dragTime: Double = 0

  // MARK: - Repeat (A-B Loop) State

  /// Start time for A-B repeat
  var repeatStartTime: Double?

  /// End time for A-B repeat
  var repeatEndTime: Double?

  // MARK: - Loop State

  /// Whether looping is enabled.
  /// When repeat points are set, loops within the A-B range.
  /// When no repeat points, loops the entire video.
  var isLoopingEnabled: Bool = true

  // MARK: - Subtitle State

  /// Current subtitle cues for subtitle-based seeking
  var cues: [Subtitle.Cue] = []

  // MARK: - Step Mode State

  /// Step mode - stops at each subtitle cue's end time
  var isStepModeEnabled: Bool = false

  /// Tracks the ID of the last cue we stopped at (prevents re-stopping on same cue)
  private var lastStoppedCueID: Subtitle.Cue.ID?

  // MARK: - Controller State

  /// The player controller (YouTube or local)
  private(set) var controller: PlayerController?

  /// Task for tracking playback time
  private var trackingTask: Task<Void, Never>?

  /// Current playback source
  private(set) var playbackSource: PlaybackSource = .youtube

  /// Local video file URL (when downloaded)
  var localFileURL: URL?

  /// Whether the controller is ready (including priming for YouTube)
  var isControllerReady: Bool {
    controller?.isReady ?? false
  }

  // MARK: - Computed Properties

  /// The time to display (drag time when dragging, otherwise current time)
  var displayTime: Double {
    isDraggingSlider ? dragTime : currentTime.value
  }

  /// Whether A-B repeat is possible (both points are set)
  var canRepeat: Bool {
    repeatStartTime != nil && repeatEndTime != nil
  }

  // MARK: - Methods

  /// Sets the A point for repeat to current time
  func setRepeatStartToCurrent() {
    repeatStartTime = currentTime.value
  }

  /// Sets the B point for repeat to current time
  func setRepeatEndToCurrent() {
    repeatEndTime = currentTime.value
  }

  /// Clears all repeat points
  func clearRepeat() {
    repeatStartTime = nil
    repeatEndTime = nil
  }

  /// Clears the repeat start point
  func clearRepeatStart() {
    repeatStartTime = nil
  }

  /// Clears the repeat end point
  func clearRepeatEnd() {
    repeatEndTime = nil
  }

  /// Checks if current time has passed the repeat end point and returns the start time if so.
  /// Only triggers when looping is enabled and both repeat points are set.
  func checkRepeatLoop() -> Double? {
    guard isLoopingEnabled,
          let startTime = repeatStartTime,
          let endTime = repeatEndTime,
          currentTime.value >= endTime else {
      return nil
    }
    return startTime
  }

  /// Checks if playback should stop at repeat end point (when looping is disabled).
  /// Returns the start time to seek to before pausing, or nil if should not stop.
  func checkRepeatEndAndStop() -> Double? {
    guard !isLoopingEnabled,
          let startTime = repeatStartTime,
          let endTime = repeatEndTime,
          currentTime.value >= endTime else {
      return nil
    }
    return startTime
  }

  /// Checks if video has ended and should loop back to the beginning
  /// Returns 0 if should loop, nil otherwise
  func checkEndOfVideoLoop() -> Double? {
    guard isLoopingEnabled,
          duration > 0,
          currentTime.value >= duration - 0.5 else {
      return nil
    }
    return 0
  }

  // MARK: - Step Mode

  /// Checks if playback should stop at current cue's end time (step mode).
  /// Returns the cue to stop at, nil otherwise.
  func checkStepModeStop() -> Subtitle.Cue? {
    guard isStepModeEnabled, !cues.isEmpty else { return nil }

    let currentTimeValue = currentTime.value

    // Find cue whose end time we've reached
    for cue in cues {
      if currentTimeValue >= cue.endTime &&
        currentTimeValue < cue.endTime + 0.15 &&
        cue.id != lastStoppedCueID {
        return cue
      }
    }
    return nil
  }

  /// Toggles loop playback
  func toggleLoop() {
    isLoopingEnabled.toggle()
  }

  // MARK: - Subtitle-based Seeking

  /// Returns the index of the current subtitle cue using binary search.
  /// "Current" means the most recently started subtitle before or at currentTime.
  /// This handles overlapping subtitles correctly by using startTime-based logic.
  /// - Returns: Index of the current cue, or nil if no subtitle has started yet
  func currentCueIndex() -> Int? {
    guard !cues.isEmpty else { return nil }

    // Binary search using swift-algorithms' partitioningIndex
    // Find the first cue whose startTime > currentTime
    let index = cues.partitioningIndex { $0.startTime > currentTime.value }

    // The cue before that (index - 1) is the "current" one
    return index > 0 ? index - 1 : nil
  }

  /// Returns the ID of the current subtitle cue.
  /// Uses the same logic as currentCueIndex() for consistency with scroll highlighting.
  var currentCueID: Subtitle.Cue.ID? {
    guard let index = currentCueIndex() else { return nil }
    return cues[index].id
  }

  /// Returns the start time of the current subtitle (Type A behavior).
  /// Always returns the start of the most recently started subtitle.
  /// - Returns: Start time of the current cue, or nil if no subtitle has started yet
  func previousSubtitleTime() -> Double? {
    guard let index = currentCueIndex() else { return nil }
    return cues[index].startTime
  }

  /// Returns the start time of the next subtitle cue relative to current time.
  /// - Returns: Start time of the next cue, or nil if at the end
  func nextSubtitleTime() -> Double? {
    guard !cues.isEmpty else { return nil }

    // Find the first cue that starts after current time
    return cues.first(where: { $0.startTime > currentTime.value })?.startTime
  }

  /// Returns the start time of the current subtitle cue.
  /// - Returns: Start time of the current cue, or nil if no matching cue
  func currentSubtitleTime() -> Double? {
    guard !cues.isEmpty else { return nil }

    // Find the cue that contains current time
    return cues.first(where: {
      $0.startTime <= currentTime.value && currentTime.value < $0.endTime
    })?.startTime
  }

  /// Returns the start time for skip-backward behavior (Type B).
  /// Always goes to the PREVIOUS subtitle (one step back from current).
  /// Uses the same currentCueIndex() logic for consistency.
  /// This enables repeated presses to navigate backward through subtitles.
  /// - Returns: Start time of the previous subtitle, or nil if at the beginning
  func previousSubtitleTimeSkip() -> Double? {
    guard let currentIndex = currentCueIndex(), currentIndex > 0 else { return nil }
    return cues[currentIndex - 1].startTime
  }

  /// Returns the start time of the next subtitle cue (skip mode).
  /// Same behavior as nextSubtitleTime() - always goes to next cue.
  /// - Returns: Start time of the next cue, or nil if at the end
  func nextSubtitleTimeSkip() -> Double? {
    return nextSubtitleTime()
  }

  // MARK: - Controller Lifecycle

  /// Loads the video and initializes the appropriate controller
  func loadVideo(videoItem: VideoItem) {
    // Prevent multiple loads
    guard controller == nil else { return }

    // Check if video is downloaded
    if videoItem.isDownloaded,
       let fileURL = videoItem.downloadedFileURL {
      // Store local file URL for later switching
      localFileURL = fileURL
      // Use local file playback by default when available
      controller = .local(LocalVideoPlayerController(url: fileURL))
      playbackSource = .local
    } else {
      // Use YouTube playback
      controller = .youtube(YouTubeVideoPlayerController(videoID: videoItem.videoID.rawValue))
      playbackSource = .youtube
    }

    startTrackingTime()
  }

  /// Cleans up resources when the view disappears
  func cleanup() {
    trackingTask?.cancel()
    trackingTask = nil

    if let controller {
      Task {
        await controller.pause()
      }
    }
  }

  // MARK: - Playback Control

  /// Seeks to the specified time
  func seek(to time: Double) {
    guard let controller else { return }
    Task {
      await controller.seek(to: time)
    }
  }


  /// Seeks backward by the specified interval
  func seekBackward(interval: Double) {
    guard let controller else { return }
    Task {
      let currentSeconds = await controller.currentTime
      let newSeconds = max(0, currentSeconds - interval)
      await controller.seek(to: newSeconds)
    }
  }


  /// Seeks forward by the specified interval
  func seekForward(interval: Double) {
    guard let controller else { return }
    Task {
      let currentSeconds = await controller.currentTime
      let newSeconds = currentSeconds + interval
      await controller.seek(to: newSeconds)
    }
  }

  /// Seeks to the previous subtitle
  func seekToPreviousSubtitle() {
    guard let controller else { return }
    Task {
      if let previousTime = previousSubtitleTime() {
        await controller.seek(to: previousTime)
      }
    }
  }

  /// Seeks to the next subtitle
  func seekToNextSubtitle() {
    guard let controller else { return }
    Task {
      if let nextTime = nextSubtitleTime() {
        await controller.seek(to: nextTime)
      }
    }
  }

  /// Seeks to the previous subtitle (skip mode - always skip current)
  func seekToPreviousSubtitleSkip() {
    guard let controller else { return }
    Task {
      if let previousTime = previousSubtitleTimeSkip() {
        await controller.seek(to: previousTime)
      }
    }
  }

  /// Seeks to the next subtitle (skip mode)
  func seekToNextSubtitleSkip() {
    guard let controller else { return }
    Task {
      if let nextTime = nextSubtitleTimeSkip() {
        await controller.seek(to: nextTime)
      }
    }
  }

  /// Seeks backward based on the specified mode
  func backward(how mode: BackwardSeekMode) {
    switch mode {
    case .seconds(let s):
      seekBackward(interval: s.rawValue)
    case .subtitle(.current):
      seekToPreviousSubtitle()
    case .subtitle(.skip):
      seekToPreviousSubtitleSkip()
    }
  }

  /// Seeks forward based on the specified mode
  func forward(how mode: ForwardSeekMode) {
    switch mode {
    case .seconds(let s):
      seekForward(interval: s.rawValue)
    case .subtitle:
      seekToNextSubtitle()
    }
  }

  /// Toggles play/pause
  func togglePlayPause() {
    guard let controller else { return }
    Task {
      if controller.isPlaying {
        await controller.pause()
      } else {
        await controller.play()
      }
    }
  }

  /// Sets the playback rate
  func setPlaybackRate(_ rate: Double) {
    guard let controller else { return }
    Task {
      await controller.setPlaybackRate(rate)
      playbackRate = rate
    }
  }

  // MARK: - Source Switching

  /// Switches playback source between YouTube and local
  func switchPlaybackSource(to source: PlaybackSource) {
    guard source != playbackSource else { return }

    // Cancel existing tracking task
    trackingTask?.cancel()

    // Stop current player before switching
    if let currentController = controller {
      Task {
        await currentController.pause()
      }
    }

    // Create new controller based on source
    switch source {
    case .youtube:
      // Need videoID for this - caller should ensure this is valid
      // For now, we'll log an error if localFileURL is used to infer videoID
      break
    case .local:
      guard let fileURL = localFileURL else { return }
      controller = .local(LocalVideoPlayerController(url: fileURL))
    }

    playbackSource = source

    // Start new time tracking
    startTrackingTime()
  }

  /// Switches to YouTube playback with the given video ID
  func switchToYouTube(videoID: String) {
    guard playbackSource != .youtube else { return }

    trackingTask?.cancel()

    if let currentController = controller {
      Task {
        await currentController.pause()
      }
    }

    controller = .youtube(YouTubeVideoPlayerController(videoID: videoID))
    playbackSource = .youtube
    startTrackingTime()
  }

  /// Switches to local playback
  func switchToLocal() {
    guard playbackSource != .local, let fileURL = localFileURL else { return }

    trackingTask?.cancel()

    if let currentController = controller {
      Task {
        await currentController.pause()
      }
    }

    controller = .local(LocalVideoPlayerController(url: fileURL))
    playbackSource = .local
    startTrackingTime()
  }

  // MARK: - Scene Phase Handling

  /// Handles scene phase changes (background/foreground)
  func handleScenePhaseChange(to newPhase: ScenePhase) {
    guard let controller else { return }

    // When entering background, pause all playback
    // (Background audio mode has been removed to comply with App Store guidelines)
    if newPhase == .background {
      Task {
        await controller.pause()
        isPlaying = false
      }
    }
  }

  // MARK: - Private Methods

  private func startTrackingTime() {
    // Cancel any existing tracking task
    trackingTask?.cancel()

    trackingTask = Task { [weak self] in
      guard let self else { return }

      // Wait for controller to be ready (priming complete for YouTube)
      while !Task.isCancelled {
        if self.controller?.isReady == true {
          break
        }
        try? await Task.sleep(for: .milliseconds(50))
      }

      guard !Task.isCancelled else { return }

      if let controller = self.controller {
        let videoDuration = await controller.duration
        self.duration = videoDuration
      }

      // Main tracking loop
      while !Task.isCancelled {
        if let controller = self.controller {
          let timeValue = await controller.currentTime
          self.currentTime.value = timeValue
          self.isPlaying = controller.isPlaying
        }

        // Check A-B repeat loop
        if let loopStartTime = self.checkRepeatLoop() {
          await self.controller?.seek(to: loopStartTime)
        }
        // Check if should stop at repeat end (when looping disabled)
        else if let startTime = self.checkRepeatEndAndStop() {
          await self.controller?.seek(to: startTime)
          await self.controller?.pause()
          self.isPlaying = false
        }
        // Check end-of-video loop
        else if let loopStartTime = self.checkEndOfVideoLoop() {
          await self.controller?.seek(to: loopStartTime)
        }
        // Check step mode stop
        else if let cue = self.checkStepModeStop() {
          self.lastStoppedCueID = cue.id
          await self.controller?.pause()
          self.isPlaying = false
        }

        try? await Task.sleep(for: .milliseconds(100))
      }
    }
  }
}
