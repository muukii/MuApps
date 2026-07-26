//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import FargMotionBlur
import Foundation

/// Whether the visible preview represents the editor's latest render recipe.
///
/// A stale player item may remain allocated while its replacement is prepared,
/// but the UI displays video only in `ready` so raw or previously processed
/// frames are never presented as the current result.
enum VideoPreviewRenderState: Equatable {
  case empty
  case preparing
  case ready
  case failed(String)

  var errorMessage: String? {
    guard case .failed(let message) = self else { return nil }
    return message
  }
}

/// Owns the preview `AVPlayer` and rebuilds it from the same complete render
/// recipe used for export, including any temporal composition asset.
@MainActor
@Observable
final class VideoPreviewModel {

  /// The latest authored recipe paired with the source it applies to.
  ///
  /// Viewport changes can reprepare this request without asking `EditorView`
  /// to rebuild editing state or resetting the playhead through `load(_:)`.
  private struct DesiredRenderRequest {
    let recipe: FargVideoRenderRecipe
    let source: VideoSource
    let colorInfo: VideoColorInfo
  }

  let player = AVPlayer()

  /// The fixed source frame used by visible editor LUT thumbnails.
  private(set) var lutPreviewSource: LUTPreviewSourceImage?

  /// Whether playback is active or waiting for enough media to continue.
  private(set) var isPlaying = false

  /// Whether audio from the editor preview is currently suppressed.
  ///
  /// This state belongs to the player rather than an individual player item, so
  /// replacing a prepared preview does not unexpectedly restore its audio.
  private(set) var isMuted = true

  /// The current playback position in seconds.
  private(set) var playbackTime: TimeInterval = 0

  /// The loaded video's duration in seconds.
  private(set) var playbackDuration: TimeInterval = 0

  /// The normalized playback position used by the editor timeline.
  var playbackProgress: Double {
    guard playbackDuration > 0 else { return 0 }
    return min(max(playbackTime / playbackDuration, 0), 1)
  }

  /// The relationship between the desired recipe and the installed player item.
  private(set) var renderState: VideoPreviewRenderState = .empty

  /// The latest asynchronous composition preparation or playback failure.
  var renderingErrorMessage: String? {
    renderState.errorMessage
  }

  private var loadedSource: VideoSource?
  private var desiredRenderRequest: DesiredRenderRequest?
  private var previewRenderTarget: FargPreviewRenderTarget?
  private var hasScheduledPreviewForLoadedSource = false
  private var compositionTask: Task<Void, Never>?
  private var compositionGeneration: UInt = 0
  private var frameCaptureTask: Task<Void, Never>?
  private var lastScheduledFrameTime: CMTime?
  private var isPlaybackRequested = false
  private var replacementSeekGeneration: UInt?
  private var isSeeking = false
  private var shouldResumePlaybackAfterSeeking = false
  private var preservedPlaybackPosition: CMTime?
  private var isRenderingSuspended = false
  // Mutated only on the main actor; read in the nonisolated deinit after the
  // last reference is gone, so unsynchronized access is safe.
  @ObservationIgnored
  nonisolated(unsafe) private var endObserver: (any NSObjectProtocol)?
  @ObservationIgnored
  nonisolated(unsafe) private var timeObserver: Any?
  @ObservationIgnored
  nonisolated(unsafe) private var playbackStatusObserver: NSKeyValueObservation?
  @ObservationIgnored
  nonisolated(unsafe) private var itemStatusObserver: NSKeyValueObservation?
  @ObservationIgnored
  nonisolated(unsafe) private var itemFailureObserver: (any NSObjectProtocol)?

  init() {
    player.actionAtItemEnd = .none
    player.isMuted = isMuted
    observePlaybackStatus()
    observePlaybackTime()
  }

  deinit {
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
    }
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    playbackStatusObserver?.invalidate()
    itemStatusObserver?.invalidate()
    if let itemFailureObserver {
      NotificationCenter.default.removeObserver(itemFailureObserver)
    }
  }

  /// Selects a source while withholding raw frames until its recipe is ready.
  func load(_ source: VideoSource) {
    guard loadedSource?.id != source.id else { return }
    compositionTask?.cancel()
    compositionGeneration &+= 1
    loadedSource = source
    desiredRenderRequest = nil
    hasScheduledPreviewForLoadedSource = false
    renderState = .preparing
    lutPreviewSource = nil
    lastScheduledFrameTime = nil
    isPlaybackRequested = true
    player.pause()
    isPlaying = false
    playbackTime = 0
    playbackDuration = 0
    preservedPlaybackPosition = nil
    replacementSeekGeneration = nil
    player.replaceCurrentItem(with: nil)
    stopObservingCurrentItem()
    scheduleFrameCapture(at: .zero, debounce: false)
  }

  /// Releases the current preview when the last video leaves the collection.
  func clear() {
    compositionTask?.cancel()
    compositionTask = nil
    compositionGeneration &+= 1
    frameCaptureTask?.cancel()
    frameCaptureTask = nil
    loadedSource = nil
    desiredRenderRequest = nil
    hasScheduledPreviewForLoadedSource = false
    renderState = .empty
    lutPreviewSource = nil
    lastScheduledFrameTime = nil
    isPlaybackRequested = false
    isPlaying = false
    playbackTime = 0
    playbackDuration = 0
    isSeeking = false
    shouldResumePlaybackAfterSeeking = false
    preservedPlaybackPosition = nil
    isRenderingSuspended = false
    replacementSeekGeneration = nil
    player.replaceCurrentItem(with: nil)
    stopObservingCurrentItem()
  }

  /// Rebuilds the live player item from one immutable render recipe.
  ///
  /// Motion blur requires a prepared multi-track asset, so every request is
  /// cancellable and generation-checked before it replaces the visible item.
  func apply(
    recipe: FargVideoRenderRecipe,
    for source: VideoSource,
    colorInfo: VideoColorInfo?
  ) {
    let request = DesiredRenderRequest(
      recipe: recipe,
      source: source,
      colorInfo: colorInfo ?? .sdrRec709
    )
    desiredRenderRequest = request
    guard isRenderingSuspended == false else { return }
    guard let previewRenderTarget else {
      renderState = .preparing
      return
    }
    schedulePreviewPreparation(
      request: request,
      target: previewRenderTarget,
      debounce: false
    )
  }

  /// Updates the operational preview resolution from the visible player area.
  ///
  /// Invalid transient layout values are ignored. The first usable viewport is
  /// applied immediately; later resize bursts are coalesced while the last
  /// valid preview remains visible.
  func updateViewport(
    sizeInPoints: CGSize,
    displayScale: CGFloat
  ) {
    guard
      let target = FargPreviewRenderTarget(
        viewportSizeInPoints: sizeInPoints,
        displayScale: displayScale
      ),
      target != previewRenderTarget
    else {
      return
    }
    previewRenderTarget = target
    guard
      isRenderingSuspended == false,
      let request = desiredRenderRequest
    else {
      return
    }
    schedulePreviewPreparation(
      request: request,
      target: target,
      debounce: hasScheduledPreviewForLoadedSource
    )
  }

  private func schedulePreviewPreparation(
    request: DesiredRenderRequest,
    target: FargPreviewRenderTarget,
    debounce: Bool
  ) {
    compositionTask?.cancel()
    compositionGeneration &+= 1
    let generation = compositionGeneration
    hasScheduledPreviewForLoadedSource = true
    player.currentItem?.cancelPendingSeeks()
    replacementSeekGeneration = nil

    if debounce == false {
      prepareVisibleStateForReplacement(
        recipe: request.recipe
      )
    }

    compositionTask = Task { [weak self] in
      do {
        if debounce {
          try await Task.sleep(for: .milliseconds(120))
          guard
            let self,
            self.compositionGeneration == generation,
            self.loadedSource?.id == request.source.id
          else {
            return
          }
          self.prepareVisibleStateForReplacement(
            recipe: request.recipe
          )
        }

        let prepared: PreparedFargVideoRender
        if request.recipe.motionBlur.isEnabled {
          prepared = try await FargVideoRenderPipeline().prepare(
            asset: request.source.asset,
            recipe: request.recipe,
            colorInfo: request.colorInfo,
            purpose: .preview(target)
          )
        } else {
          prepared = try FargVideoRenderPipeline().prepareSingleFrame(
            asset: request.source.asset,
            recipe: request.recipe,
            colorInfo: request.colorInfo,
            purpose: .preview(target)
          )
        }
        try Task.checkCancellation()
        guard
          let self,
          self.compositionGeneration == generation,
          self.loadedSource?.id == request.source.id,
          self.previewRenderTarget == target
        else {
          return
        }
        self.install(
          prepared: prepared,
          generation: generation
        )
      } catch is CancellationError {
        return
      } catch {
        guard
          let self,
          self.compositionGeneration == generation,
          self.loadedSource?.id == request.source.id
        else {
          return
        }
        self.failRender(
          message: error.localizedDescription,
          generation: generation
        )
      }
    }
  }

  /// Hides a stale temporal result only when replacement work actually begins.
  ///
  /// LUT-only items remain attached because their composition can be replaced
  /// in place without disrupting the decoder, playhead, or audio clock.
  private func prepareVisibleStateForReplacement(
    recipe: FargVideoRenderRecipe
  ) {
    guard recipe.motionBlur.isEnabled else {
      if player.currentItem == nil {
        renderState = .preparing
      }
      return
    }

    renderState = .preparing
    detachCurrentItem(preservingPlaybackPosition: true)
    isPlaying = false
  }

  /// Invalidates a preview when recipe creation fails before preparation starts.
  func failCurrentRender(_ error: any Error) {
    compositionTask?.cancel()
    compositionTask = nil
    compositionGeneration &+= 1
    desiredRenderRequest = nil
    replacementSeekGeneration = nil
    failRender(
      message: error.localizedDescription,
      generation: compositionGeneration
    )
  }

  /// Starts or resumes playback.
  func play() {
    isPlaybackRequested = true
    guard renderState == .ready else { return }
    player.play()
  }

  /// Pauses playback at its current position.
  func pause() {
    isPlaybackRequested = false
    isPlaying = false
    player.pause()
  }

  /// Detaches the expensive temporal pipeline while another renderer owns it.
  ///
  /// Pausing alone keeps the player item, custom compositor, VideoToolbox
  /// session, and IOSurface pool alive. Export uses a separate compositor, so
  /// releasing the preview item prevents both pipelines from overlapping.
  func suspendRendering() {
    isRenderingSuspended = true
    compositionTask?.cancel()
    compositionTask = nil
    compositionGeneration &+= 1

    isPlaybackRequested = false
    isPlaying = false
    detachCurrentItem(preservingPlaybackPosition: true)
    renderState = loadedSource == nil ? .empty : .preparing
  }

  /// Allows the editor to install its latest recipe after exclusive work ends.
  func resumeRendering() {
    isRenderingSuspended = false
  }

  /// Switches between playing and paused states.
  func togglePlayback() {
    if isPlaying {
      pause()
    } else {
      play()
    }
  }

  /// Switches preview audio between its audible and muted states.
  func toggleMute() {
    isMuted.toggle()
    player.isMuted = isMuted
  }

  /// Pauses playback and remembers whether it should resume after scrubbing.
  func beginSeeking() {
    guard isSeeking == false else { return }
    isSeeking = true
    shouldResumePlaybackAfterSeeking = isPlaying
    pause()
  }

  /// Seeks to a normalized position within the current video.
  func seek(toProgress progress: Double) {
    guard playbackDuration > 0 else { return }
    let boundedProgress = min(max(progress, 0), 1)
    let seconds = playbackDuration * boundedProgress
    playbackTime = seconds
    player.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 600),
      toleranceBefore: .zero,
      toleranceAfter: .zero
    )
  }

  /// Completes a scrub and restores playback only if it was active beforehand.
  func endSeeking() {
    guard isSeeking else { return }
    isSeeking = false
    let shouldResume = shouldResumePlaybackAfterSeeking
    shouldResumePlaybackAfterSeeking = false
    if shouldResume {
      play()
    }
  }

  /// Captures only stopped source frames; live LUT cards never follow playback.
  private func observePlaybackStatus() {
    playbackStatusObserver = player.observe(
      \.timeControlStatus,
      options: [.new]
    ) { [weak self] player, _ in
      Task { @MainActor [weak self] in
        self?.isPlaying = player.timeControlStatus != .paused
        guard player.timeControlStatus == .paused else { return }
        self?.scheduleFrameCapture(
          at: player.currentTime(),
          debounce: true
        )
      }
    }
  }

  /// A seek while already paused does not change `timeControlStatus`.
  ///
  /// The periodic callback observes those timeline changes and debounces image
  /// generation until the scrubber settles.
  private func observePlaybackTime() {
    let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: interval,
      queue: .main
    ) { [weak self] time in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.updatePlaybackClock(at: time)
        guard self.player.timeControlStatus == .paused else { return }
        self.scheduleFrameCapture(at: time, debounce: true)
      }
    }
  }

  private func updatePlaybackClock(at time: CMTime) {
    if isSeeking == false, time.seconds.isFinite {
      playbackTime = max(time.seconds, 0)
    }

    guard
      let duration = player.currentItem?.duration.seconds,
      duration.isFinite,
      duration > 0
    else {
      return
    }
    playbackDuration = duration
  }

  private func scheduleFrameCapture(
    at time: CMTime,
    debounce: Bool
  ) {
    guard let source = loadedSource else { return }
    guard lastScheduledFrameTime != time else { return }
    lastScheduledFrameTime = time
    frameCaptureTask?.cancel()
    frameCaptureTask = Task { [weak self] in
      if debounce {
        try? await Task.sleep(for: .milliseconds(180))
      }
      guard Task.isCancelled == false else { return }

      let generator = AVAssetImageGenerator(asset: source.asset)
      generator.appliesPreferredTrackTransform = true
      let maximumPixelSize = CGFloat(
        LUTPreviewSourceImage.maximumPixelSize
      )
      generator.maximumSize = CGSize(
        width: maximumPixelSize,
        height: maximumPixelSize
      )
      // A stopped preview must represent the playhead, not a nearby keyframe.
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      do {
        let result = try await generator.image(at: time)
        guard
          Task.isCancelled == false,
          self?.loadedSource?.id == source.id
        else {
          return
        }
        self?.lutPreviewSource = LUTPreviewSourceImage(
          id: UUID().uuidString,
          image: result.image
        )
      } catch is CancellationError {
        return
      } catch {
        // The video player remains usable even if this optional still fails.
        if self?.lastScheduledFrameTime == time {
          self?.lastScheduledFrameTime = nil
        }
      }
    }
  }

  private func observe(
    item: AVPlayerItem,
    generation: UInt
  ) {
    stopObservingCurrentItem()

    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        guard
          let self,
          self.compositionGeneration == generation,
          self.player.currentItem === item
        else {
          return
        }
        self.playbackTime = 0
        self.player.seek(to: .zero)
        self.play()
      }
    }

    itemStatusObserver = item.observe(
      \.status,
      options: [.initial, .new]
    ) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.handleCurrentItemStatus(generation: generation)
      }
    }

    itemFailureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime,
      object: item,
      queue: .main
    ) { [weak self] notification in
      let message =
        (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error)?
        .localizedDescription
      Task { @MainActor [weak self] in
        self?.failRender(
          message: message ?? "The preview renderer failed.",
          generation: generation
        )
      }
    }
  }

  private func stopObservingCurrentItem() {
    if let endObserver {
      NotificationCenter.default.removeObserver(endObserver)
      self.endObserver = nil
    }
    itemStatusObserver?.invalidate()
    itemStatusObserver = nil
    if let itemFailureObserver {
      NotificationCenter.default.removeObserver(itemFailureObserver)
      self.itemFailureObserver = nil
    }
  }

  private func handleCurrentItemStatus(generation: UInt) {
    guard
      compositionGeneration == generation,
      let item = player.currentItem
    else {
      return
    }

    switch item.status {
    case .unknown:
      break
    case .readyToPlay:
      guard replacementSeekGeneration != generation else { return }
      renderState = .ready
      if isPlaybackRequested {
        player.play()
      }
    case .failed:
      failRender(
        message: item.error?.localizedDescription ?? "The preview renderer failed.",
        generation: generation
      )
    @unknown default:
      failRender(
        message: "The preview renderer entered an unknown state.",
        generation: generation
      )
    }
  }

  private func failRender(
    message: String,
    generation: UInt
  ) {
    guard compositionGeneration == generation else { return }
    player.pause()
    isPlaying = false
    replacementSeekGeneration = nil
    detachCurrentItem(preservingPlaybackPosition: true)
    renderState = .failed(message)
  }

  private func detachCurrentItem(
    preservingPlaybackPosition: Bool
  ) {
    player.currentItem?.cancelPendingSeeks()
    if preservingPlaybackPosition {
      let currentTime = player.currentTime()
      if currentTime.seconds.isFinite, currentTime.seconds >= 0 {
        preservedPlaybackPosition = currentTime
      }
    }
    replacementSeekGeneration = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    stopObservingCurrentItem()
  }

  private func install(
    prepared: PreparedFargVideoRender,
    generation: UInt
  ) {
    guard compositionGeneration == generation else { return }

    if let sourceAsset = loadedSource?.asset,
      prepared.asset === sourceAsset,
      let item = player.currentItem,
      item.asset === sourceAsset
    {
      // LUT-only edits can update the existing item without disrupting its
      // decoder, playhead, or audio clock.
      item.videoComposition = prepared.videoComposition
      observe(item: item, generation: generation)
      return
    }

    let currentTime = player.currentTime()
    // The initial editor load has no installed item, so AVPlayer reports an
    // invalid time that AVPlayerItem cannot seek to after replacement.
    let playbackPosition =
      preservedPlaybackPosition
      ?? (currentTime.seconds.isFinite && currentTime.seconds >= 0
        ? currentTime
        : .zero)
    renderState = .preparing
    player.pause()
    isPlaying = false
    replacementSeekGeneration = generation
    let item = AVPlayerItem(asset: prepared.asset)
    item.videoComposition = prepared.videoComposition
    player.replaceCurrentItem(with: item)
    observe(item: item, generation: generation)
    player.seek(
      to: playbackPosition,
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] finished in
      Task { @MainActor [weak self] in
        guard
          let self,
          self.compositionGeneration == generation,
          self.replacementSeekGeneration == generation
        else {
          return
        }
        self.replacementSeekGeneration = nil
        if finished {
          self.preservedPlaybackPosition = nil
          self.handleCurrentItemStatus(generation: generation)
        } else {
          self.failRender(
            message: "Färg couldn't position the prepared preview.",
            generation: generation
          )
        }
      }
    }
  }
}
