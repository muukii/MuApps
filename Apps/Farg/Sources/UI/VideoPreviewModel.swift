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

/// Identifies how narrowly the editor may update an existing Preview recipe.
///
/// Motion-blur-only and grain-only edits can preserve both the current video
/// composition and player item when only live frame parameters changed.
enum VideoPreviewRecipeChange: Equatable, Sendable {
  case complete
  case motionBlur
  case grain
}

/// Owns the preview `AVPlayer` and rebuilds it from the same complete render
/// recipe used for export, including any temporal composition asset.
@MainActor
@Observable
final class VideoPreviewModel {

  /// The latest authored recipe paired with the source it applies to.
  ///
  /// Recipe changes can reprepare this request without asking `EditorView`
  /// to rebuild editing state or resetting the playhead through `load(_:)`.
  private struct DesiredRenderRequest {
    let recipe: FargVideoRenderRecipe
    let source: VideoSource
    let colorInfo: VideoColorInfo
  }

  /// Source-owned temporal topology reused by every Preview presentation mode.
  ///
  /// The three-track asset is independent of editor layout, LUT, enablement,
  /// Strength, and grain parameters. Those values change only the composition
  /// installed on this source or the live values read by its compositor.
  private struct TemporalPreviewState {
    let sourceID: VideoSource.ID
    let source: PreparedMotionBlurSource
    let strength: MotionBlurStrengthSource
    let grain: GrainParameterSource
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

  /// The display-oriented ratio used while an item or composition is replaced.
  ///
  /// Keeping this outside `AVPlayerItem` prevents a transient 16:9 fallback
  /// from feeding a false viewport back into portrait Preview preparation.
  private(set) var presentationAspectRatio: CGFloat = 16 / 9

  /// The relationship between the desired recipe and the installed player item.
  private(set) var renderState: VideoPreviewRenderState = .empty

  /// The latest asynchronous composition preparation or playback failure.
  var renderingErrorMessage: String? {
    renderState.errorMessage
  }

  private var loadedSource: VideoSource?
  private var desiredRenderRequest: DesiredRenderRequest?
  private var temporalPreviewState: TemporalPreviewState?
  /// The most recent stable Editor window target, retained for the next clip.
  private var editorWindowRenderTarget: FargPreviewRenderTarget?
  /// The render target locked while the currently selected clip is active.
  ///
  /// Tab controls may alter the player surface but must not alter this target.
  private var previewRenderTarget: FargPreviewRenderTarget?
  private var hasInstalledPreviewForLoadedSource = false
  private var preparingTemporalSourceID: VideoSource.ID?
  private var sourcePreparationTask: Task<Void, Never>?
  private var compositionUpdateTask: Task<Void, Never>?
  private var sourceGeneration: UInt = 0
  private var compositionRevision: UInt = 0
  private var itemGeneration: UInt = 0
  private var frameCaptureTask: Task<Void, Never>?
  private var lastScheduledFrameTime: CMTime?
  private var isPlaybackRequested = false
  private var replacementSeekGeneration: UInt?
  private var pendingCompositionAfterReplacementSeek: PreparedFargVideoRender?
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
    sourcePreparationTask?.cancel()
    sourcePreparationTask = nil
    compositionUpdateTask?.cancel()
    compositionUpdateTask = nil
    sourceGeneration &+= 1
    compositionRevision &+= 1
    itemGeneration &+= 1
    loadedSource = source
    desiredRenderRequest = nil
    temporalPreviewState = nil
    previewRenderTarget = editorWindowRenderTarget
    preparingTemporalSourceID = nil
    hasInstalledPreviewForLoadedSource = false
    renderState = .preparing
    lutPreviewSource = nil
    lastScheduledFrameTime = nil
    isPlaybackRequested = true
    player.pause()
    isPlaying = false
    playbackTime = 0
    playbackDuration = 0
    presentationAspectRatio = 16 / 9
    preservedPlaybackPosition = nil
    replacementSeekGeneration = nil
    pendingCompositionAfterReplacementSeek = nil
    player.currentItem?.cancelPendingSeeks()
    player.replaceCurrentItem(with: nil)
    stopObservingCurrentItem()
    scheduleFrameCapture(at: .zero, debounce: false)
  }

  /// Releases the current preview when the last video leaves the collection.
  func clear() {
    sourcePreparationTask?.cancel()
    sourcePreparationTask = nil
    compositionUpdateTask?.cancel()
    compositionUpdateTask = nil
    sourceGeneration &+= 1
    compositionRevision &+= 1
    itemGeneration &+= 1
    frameCaptureTask?.cancel()
    frameCaptureTask = nil
    loadedSource = nil
    desiredRenderRequest = nil
    temporalPreviewState = nil
    previewRenderTarget = nil
    preparingTemporalSourceID = nil
    hasInstalledPreviewForLoadedSource = false
    renderState = .empty
    lutPreviewSource = nil
    lastScheduledFrameTime = nil
    isPlaybackRequested = false
    isPlaying = false
    playbackTime = 0
    playbackDuration = 0
    presentationAspectRatio = 16 / 9
    isSeeking = false
    shouldResumePlaybackAfterSeeking = false
    preservedPlaybackPosition = nil
    isRenderingSuspended = false
    replacementSeekGeneration = nil
    pendingCompositionAfterReplacementSeek = nil
    player.currentItem?.cancelPendingSeeks()
    player.replaceCurrentItem(with: nil)
    stopObservingCurrentItem()
  }

  /// Applies one immutable recipe to the source's reusable temporal topology.
  ///
  /// Only a source change creates another topology and player item. Enablement,
  /// viewport, and LUT changes replace the item's video composition in place;
  /// a Strength-only edit updates the value consumed by subsequent frames.
  func apply(
    recipe: FargVideoRenderRecipe,
    for source: VideoSource,
    colorInfo: VideoColorInfo?,
    change: VideoPreviewRecipeChange = .complete
  ) {
    let previousRequest = desiredRenderRequest
    let request = DesiredRenderRequest(
      recipe: recipe,
      source: source,
      colorInfo: colorInfo ?? .sdrRec709
    )
    desiredRenderRequest = request
    guard isRenderingSuspended == false else { return }

    guard
      let temporalPreviewState,
      temporalPreviewState.sourceID == source.id
    else {
      renderState = .preparing
      prepareTemporalSourceIfNeeded(for: source)
      return
    }

    temporalPreviewState.strength.update(
      strength: recipe.motionBlur.strength
    )
    temporalPreviewState.grain.update(settings: recipe.grain)

    if change == .motionBlur,
      previousRequest?.source.id == source.id,
      previousRequest?.recipe.motionBlur.isEnabled
        == recipe.motionBlur.isEnabled,
      player.currentItem?.asset === temporalPreviewState.source.asset
    {
      // Strength is sampled once at the start of each compositor request, so
      // this edit neither invalidates queued playback nor resets the playhead.
      return
    }

    if change == .grain,
      previousRequest?.source.id == source.id,
      previousRequest?.recipe.grain.isEnabled == recipe.grain.isEnabled,
      player.currentItem?.asset === temporalPreviewState.source.asset
    {
      // Grain parameters are sampled once per compositor request, so intensity
      // and size edits ride the live source without a composition replacement.
      return
    }

    guard previewRenderTarget != nil else {
      renderState = .preparing
      return
    }
    scheduleCompositionUpdate(debounce: false)
  }

  /// Captures a bounded Preview quality target from the Editor window.
  ///
  /// The active clip keeps its target even when the player surface changes.
  /// This prevents a tab's layout animation from replacing the custom
  /// compositor's render context mid-request. A later source selection uses
  /// the newest valid Editor window target.
  func updateEditorWindow(
    sizeInPoints: CGSize,
    displayScale: CGFloat
  ) {
    guard
      let target = FargPreviewRenderTarget(
        editorWindowSizeInPoints: sizeInPoints,
        displayScale: displayScale
      ),
      target != editorWindowRenderTarget
    else {
      return
    }
    editorWindowRenderTarget = target
    guard previewRenderTarget == nil else { return }
    previewRenderTarget = target
    guard
      isRenderingSuspended == false,
      let request = desiredRenderRequest
    else {
      return
    }
    guard
      let temporalPreviewState,
      temporalPreviewState.sourceID == request.source.id
    else {
      prepareTemporalSourceIfNeeded(for: request.source)
      return
    }
    scheduleCompositionUpdate(
      debounce: hasInstalledPreviewForLoadedSource
    )
  }

  /// Builds the source-owned three-track asset exactly once per selected clip.
  private func prepareTemporalSourceIfNeeded(for source: VideoSource) {
    guard temporalPreviewState?.sourceID != source.id else { return }
    guard preparingTemporalSourceID != source.id else { return }

    sourcePreparationTask?.cancel()
    preparingTemporalSourceID = source.id
    let generation = sourceGeneration
    sourcePreparationTask = Task { [weak self] in
      do {
        let preparedSource =
          try await FargVideoRenderPipeline()
          .prepareTemporalPreviewSource(asset: source.asset)
        try Task.checkCancellation()
        guard
          let self,
          self.sourceGeneration == generation,
          self.loadedSource?.id == source.id
        else {
          return
        }
        let strength = MotionBlurStrengthSource(
          strength:
            self.desiredRenderRequest?.recipe.motionBlur.strength
            ?? MotionBlurSettings.disabled.strength
        )
        let grain = GrainParameterSource(
          settings: self.desiredRenderRequest?.recipe.grain ?? .disabled
        )
        self.updatePresentationAspectRatio(
          from: preparedSource.sourceDisplaySize
        )
        self.temporalPreviewState = TemporalPreviewState(
          sourceID: source.id,
          source: preparedSource,
          strength: strength,
          grain: grain
        )
        self.preparingTemporalSourceID = nil
        self.sourcePreparationTask = nil

        guard
          self.isRenderingSuspended == false,
          self.previewRenderTarget != nil,
          self.desiredRenderRequest?.source.id == source.id
        else {
          return
        }
        self.scheduleCompositionUpdate(debounce: false)
      } catch is CancellationError {
        return
      } catch {
        guard
          let self,
          self.sourceGeneration == generation,
          self.loadedSource?.id == source.id
        else {
          return
        }
        self.preparingTemporalSourceID = nil
        self.sourcePreparationTask = nil
        self.failRender(
          message: error.localizedDescription
        )
      }
    }
  }

  /// Coalesces operational resize bursts without rebuilding source topology.
  private func scheduleCompositionUpdate(debounce: Bool) {
    compositionUpdateTask?.cancel()
    compositionRevision &+= 1
    let revision = compositionRevision

    guard debounce else {
      installLatestComposition(revision: revision)
      return
    }

    compositionUpdateTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(120))
        guard
          let self,
          self.compositionRevision == revision
        else {
          return
        }
        self.compositionUpdateTask = nil
        self.installLatestComposition(revision: revision)
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }
  }

  /// Installs the latest composition while preserving the current player item.
  private func installLatestComposition(revision: UInt) {
    guard
      compositionRevision == revision,
      isRenderingSuspended == false,
      let request = desiredRenderRequest,
      let target = previewRenderTarget,
      let temporalPreviewState,
      temporalPreviewState.sourceID == request.source.id
    else {
      return
    }

    temporalPreviewState.strength.update(
      strength: request.recipe.motionBlur.strength
    )
    temporalPreviewState.grain.update(settings: request.recipe.grain)

    do {
      let prepared = try FargVideoRenderPipeline().makeTemporalPreview(
        source: temporalPreviewState.source,
        recipe: request.recipe,
        colorInfo: request.colorInfo,
        target: target,
        strengthSource: temporalPreviewState.strength,
        grainSource: temporalPreviewState.grain
      )
      guard compositionRevision == revision else { return }
      install(prepared: prepared)
    } catch {
      guard compositionRevision == revision else { return }
      failRender(message: error.localizedDescription)
    }
  }

  /// Invalidates a preview when recipe creation fails before preparation starts.
  func failCurrentRender(_ error: any Error) {
    sourcePreparationTask?.cancel()
    sourcePreparationTask = nil
    preparingTemporalSourceID = nil
    compositionUpdateTask?.cancel()
    compositionUpdateTask = nil
    sourceGeneration &+= 1
    compositionRevision &+= 1
    desiredRenderRequest = nil
    replacementSeekGeneration = nil
    pendingCompositionAfterReplacementSeek = nil
    failRender(message: error.localizedDescription)
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
    sourcePreparationTask?.cancel()
    sourcePreparationTask = nil
    preparingTemporalSourceID = nil
    compositionUpdateTask?.cancel()
    compositionUpdateTask = nil
    sourceGeneration &+= 1
    compositionRevision &+= 1

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
    itemGeneration: UInt
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
          self.itemGeneration == itemGeneration,
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
        self?.handleCurrentItemStatus(itemGeneration: itemGeneration)
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
        guard
          let self,
          self.itemGeneration == itemGeneration,
          self.player.currentItem === item
        else {
          return
        }
        self.failRender(
          message: message ?? "The preview renderer failed."
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

  private func handleCurrentItemStatus(itemGeneration: UInt) {
    guard
      self.itemGeneration == itemGeneration,
      let item = player.currentItem
    else {
      return
    }

    switch item.status {
    case .unknown:
      break
    case .readyToPlay:
      guard replacementSeekGeneration != itemGeneration else { return }
      renderState = .ready
      if isPlaybackRequested {
        player.play()
      }
    case .failed:
      failRender(
        message: item.error?.localizedDescription ?? "The preview renderer failed."
      )
    @unknown default:
      failRender(
        message: "The preview renderer entered an unknown state."
      )
    }
  }

  private func failRender(message: String) {
    player.pause()
    isPlaying = false
    replacementSeekGeneration = nil
    detachCurrentItem(preservingPlaybackPosition: true)
    renderState = .failed(message)
  }

  private func detachCurrentItem(
    preservingPlaybackPosition: Bool
  ) {
    itemGeneration &+= 1
    player.currentItem?.cancelPendingSeeks()
    if preservingPlaybackPosition {
      let currentTime = player.currentTime()
      if currentTime.seconds.isFinite, currentTime.seconds >= 0 {
        preservedPlaybackPosition = currentTime
      }
    }
    replacementSeekGeneration = nil
    pendingCompositionAfterReplacementSeek = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    stopObservingCurrentItem()
  }

  private func install(prepared: PreparedFargVideoRender) {
    if let item = player.currentItem,
      item.asset === prepared.asset
    {
      if replacementSeekGeneration == itemGeneration {
        // A portrait-driven viewport correction can arrive while the initial
        // replacement seek is still positioning this item. Keep only the
        // latest composition and install it after that seek completes.
        pendingCompositionAfterReplacementSeek = prepared
        return
      }
      // Mode, LUT, color, and viewport changes remain on the same decoder,
      // playhead, and audio clock.
      item.videoComposition = prepared.videoComposition
      hasInstalledPreviewForLoadedSource = true
      if item.status == .readyToPlay {
        renderState = .ready
      }
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
    itemGeneration &+= 1
    let generation = itemGeneration
    replacementSeekGeneration = generation
    pendingCompositionAfterReplacementSeek = nil
    let item = AVPlayerItem(asset: prepared.asset)
    item.videoComposition = prepared.videoComposition
    player.replaceCurrentItem(with: item)
    observe(item: item, itemGeneration: generation)
    hasInstalledPreviewForLoadedSource = true
    player.seek(
      to: playbackPosition,
      toleranceBefore: .zero,
      toleranceAfter: .zero
    ) { [weak self] finished in
      Task { @MainActor [weak self] in
        guard
          let self,
          self.itemGeneration == generation,
          self.replacementSeekGeneration == generation
        else {
          return
        }
        self.replacementSeekGeneration = nil
        if finished {
          self.preservedPlaybackPosition = nil
          if let pendingComposition =
            self.pendingCompositionAfterReplacementSeek,
            pendingComposition.asset === item.asset
          {
            item.videoComposition =
              pendingComposition.videoComposition
          }
          self.pendingCompositionAfterReplacementSeek = nil
          self.handleCurrentItemStatus(itemGeneration: generation)
        } else {
          self.failRender(
            message: "Färg couldn't position the prepared preview."
          )
        }
      }
    }
  }

  private func updatePresentationAspectRatio(from renderSize: CGSize) {
    guard
      renderSize.width.isFinite,
      renderSize.height.isFinite,
      renderSize.width > 0,
      renderSize.height > 0
    else {
      return
    }
    presentationAspectRatio = renderSize.width / renderSize.height
  }
}
