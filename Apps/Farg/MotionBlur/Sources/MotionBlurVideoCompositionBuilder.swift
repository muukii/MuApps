//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import CoreImage
import Foundation

/// Selects how a prepared temporal asset is rendered without replacing it.
///
/// `currentFrame` is Färg's semantic motion-blur strength zero. VideoToolbox
/// itself accepts only 1...100, so the current-frame mode bypasses it entirely
/// and asks AVFoundation to decode only the current temporal track.
public enum MotionBlurRenderingMode: Sendable {
  case currentFrame
  case opticalFlow(strength: MotionBlurStrengthSource)
}

/// A source asset whose current, previous, and next tracks are prepared once.
///
/// The topology is independent of viewport size, LUT state, and whether Optical
/// Flow is currently enabled. A composition made by
/// `MotionBlurVideoCompositionBuilder.makeVideoComposition` must stay paired
/// with this `asset` because its instructions reference this asset's track IDs.
public struct PreparedMotionBlurSource: @unchecked Sendable {
  public let asset: AVAsset

  /// The source's display-oriented dimensions before viewport fitting.
  ///
  /// Preview uses this stable ratio for layout so even-pixel render rounding
  /// cannot feed a slightly different aspect ratio back into viewport sizing.
  public let sourceDisplaySize: CGSize

  fileprivate let duration: CMTime
  fileprivate let frameDuration: CMTime
  fileprivate let previousTrackID: CMPersistentTrackID
  fileprivate let currentTrackID: CMPersistentTrackID
  fileprivate let nextTrackID: CMPersistentTrackID
  fileprivate let naturalSize: CGSize
  fileprivate let preferredTransform: CGAffineTransform
}

/// A source asset prepared with temporal-neighbor tracks and the composition
/// that turns those tracks into one Optical Flow motion-blurred frame.
///
/// Both values must travel together. The video composition asks for track IDs
/// that exist only in `asset`, so assigning it to the original asset is invalid.
public struct PreparedMotionBlurVideo: @unchecked Sendable {
  public let asset: AVAsset
  public let videoComposition: AVMutableVideoComposition

  public init(
    asset: AVAsset,
    videoComposition: AVMutableVideoComposition
  ) {
    self.asset = asset
    self.videoComposition = videoComposition
  }
}

/// The spatial policy used by the temporal processor.
///
/// This is operational render state rather than part of
/// `MotionBlurSettings`: preview can process viewport-sized frames while
/// export continues to use the source display resolution.
public enum MotionBlurRenderTarget: Equatable, Sendable {
  /// Preserve the source display resolution.
  case source

  /// Uniformly fit the display-oriented source inside a pixel size whose
  /// dimensions are both at least two.
  case fitWithin(CGSize)
}

/// The buffer stage at which a frame-geometry contract failed.
public enum MotionBlurFrameStage: String, Equatable, Sendable {
  case previousSource
  case currentSource
  case nextSource
  case previousProcessor
  case currentProcessor
  case nextProcessor
  case processorDestination
  case renderContext
}

/// Errors raised before or during Optical Flow composition.
public enum MotionBlurError: LocalizedError, Equatable, Sendable {
  case unavailable
  case missingVideoTrack
  case invalidVideoDuration
  case invalidFrameSize(CGSize)
  case unsupportedFrameSize(width: Int, height: Int)
  case cannotCreateCompositionTrack
  case cannotCreateFrameProcessor
  case unsupportedPixelFormat(OSType)
  case cannotCreatePixelBuffer
  case cannotCreateRenderContextPixelBuffer
  case cannotCreateProcessorPixelBuffer
  case cannotCreateProcessorPixelBufferPool
  case missingSourceFrame(MotionBlurFrameStage)
  case cannotWrapPixelBuffer
  case cannotCreateParameters
  case inconsistentFrameGeometry(
    stage: MotionBlurFrameStage,
    expected: CGSize,
    actual: CGSize
  )

  public var errorDescription: String? {
    switch self {
    case .unavailable:
      return "Optical Flow motion blur isn't available on this device."
    case .missingVideoTrack:
      return "The selected file does not contain a video track."
    case .invalidVideoDuration:
      return "The selected video has an invalid duration."
    case .invalidFrameSize(let size):
      return "The source frame size is invalid (\(size.width)×\(size.height))."
    case .unsupportedFrameSize(let width, let height):
      return
        "Optical Flow motion blur supports working frames that fit within "
        + "4096×2160 in either orientation; this frame is \(width)×\(height)."
    case .cannotCreateCompositionTrack:
      return "Färg couldn't prepare the temporal video tracks."
    case .cannotCreateFrameProcessor:
      return "Färg couldn't start the Optical Flow motion-blur processor."
    case .unsupportedPixelFormat(let pixelFormat):
      return
        "Färg received an unsupported Optical Flow pixel format "
        + "(\(Self.fourCharacterCode(pixelFormat)))."
    case .cannotCreatePixelBuffer:
      return "Färg couldn't allocate a motion-blur video frame."
    case .cannotCreateRenderContextPixelBuffer:
      return "Färg couldn't allocate the current Preview output frame."
    case .cannotCreateProcessorPixelBuffer:
      return "Färg couldn't allocate an Optical Flow working frame."
    case .cannotCreateProcessorPixelBufferPool:
      return "Färg couldn't create the Optical Flow working-frame pool."
    case .missingSourceFrame(let stage):
      return "Färg didn't receive the required \(stage.rawValue) video frame."
    case .cannotWrapPixelBuffer:
      return "Färg couldn't prepare an IOSurface-backed video frame."
    case .cannotCreateParameters:
      return "Färg couldn't configure motion blur for this frame."
    case .inconsistentFrameGeometry(let stage, let expected, let actual):
      return
        "Färg received an incompatible \(stage.rawValue) frame size "
        + "(\(actual.width)×\(actual.height)); expected "
        + "\(expected.width)×\(expected.height)."
    }
  }

  private static func fourCharacterCode(_ value: OSType) -> String {
    let bytes = [
      UInt8((value >> 24) & 0xFF),
      UInt8((value >> 16) & 0xFF),
      UInt8((value >> 8) & 0xFF),
      UInt8(value & 0xFF),
    ]
    return String(bytes: bytes, encoding: .macOSRoman) ?? "\(value)"
  }
}

/// The four spatial coordinate spaces used by one temporal composition.
///
/// Video files may store portrait pixels directly or store landscape pixels
/// with a portrait track transform. Keeping each size explicit prevents a
/// display-oriented viewport from being mistaken for VideoToolbox's encoded
/// processor dimensions.
struct MotionBlurFrameGeometry: Equatable, Sendable {
  /// Pixel dimensions emitted by the decoder before any display transform.
  let sourceEncodedSize: CGSize

  /// Full source dimensions after applying the track's display transform.
  let sourceDisplaySize: CGSize

  /// Pixel dimensions supplied to every VideoToolbox source and destination.
  let processorInputSize: CGSize

  /// Display-oriented dimensions emitted by the video composition.
  let compositionRenderSize: CGSize

  /// Maps a decoded source buffer into `processorInputSize`.
  let sourceToProcessorTransform: CGAffineTransform

  /// Maps a processed VideoToolbox buffer into `compositionRenderSize`.
  let processorToRenderTransform: CGAffineTransform

  /// Whether decoded buffers already satisfy the processor geometry.
  let usesSourceBuffersDirectly: Bool
}

/// Builds the multi-track input required by an `AVVideoCompositing` temporal
/// effect.
///
/// The source movie is copied into three composition tracks at equal temporal
/// offsets around each output frame. A fixed nominal cadence gives VideoToolbox
/// honest t-d, t, and t+d timestamps even when the source movie is variable
/// frame rate. The caller's `postProcessor` runs after motion blur, which lets
/// Färg apply its Brightroom parametric document in the same composition pass.
/// The frame's composition time is supplied as an explicit evaluation input so
/// time-sensitive single-frame features remain reproducible across renders.
public struct MotionBlurVideoCompositionBuilder: Sendable {

  public typealias PostProcessor =
    @Sendable (
      _ motionBlurredImage: CIImage,
      _ renderExtent: CGRect,
      _ compositionTime: CMTime
    ) throws -> CIImage

  public var quality: MotionBlurQuality
  public var ciContext: CIContext
  public var allowsRealtimeFrameDropping: Bool

  public init(
    quality: MotionBlurQuality = .normal,
    ciContext: CIContext,
    allowsRealtimeFrameDropping: Bool = false
  ) {
    self.quality = quality
    self.ciContext = ciContext
    self.allowsRealtimeFrameDropping = allowsRealtimeFrameDropping
  }

  public func prepare(
    asset sourceAsset: AVAsset,
    settings: MotionBlurSettings,
    renderTarget: MotionBlurRenderTarget,
    outputColorSpace: CGColorSpace? = nil,
    postProcessor: @escaping PostProcessor
  ) async throws -> PreparedMotionBlurVideo {
    guard settings.isEnabled else {
      preconditionFailure("Use the ordinary single-frame renderer when motion blur is disabled.")
    }
    guard MotionBlurAvailability.isSupported else {
      throw MotionBlurError.unavailable
    }
    let source = try await prepareSource(asset: sourceAsset)
    let videoComposition = try makeVideoComposition(
      source: source,
      mode: .opticalFlow(
        strength: MotionBlurStrengthSource(strength: settings.strength)
      ),
      renderTarget: renderTarget,
      outputColorSpace: outputColorSpace,
      postProcessor: postProcessor
    )
    return PreparedMotionBlurVideo(
      asset: source.asset,
      videoComposition: videoComposition
    )
  }

  /// Builds the reusable three-track topology independently of render settings.
  ///
  /// Viewport geometry, LUT state, and the current motion-blur mode belong to
  /// the video composition rather than this source. Preview can therefore keep
  /// one player item while replacing only its `videoComposition`.
  public func prepareSource(
    asset sourceAsset: AVAsset
  ) async throws -> PreparedMotionBlurSource {
    try Task.checkCancellation()
    let sourceVideoTracks = try await sourceAsset.loadTracks(withMediaType: .video)
    try Task.checkCancellation()
    guard let sourceVideoTrack = sourceVideoTracks.first else {
      throw MotionBlurError.missingVideoTrack
    }

    // `AVAssetTrack` is not Sendable, so load its properties in sequence rather
    // than sending one Objective-C instance into concurrent child tasks.
    let sourceTimeRange = try await sourceVideoTrack.load(.timeRange)
    let naturalSize = try await sourceVideoTrack.load(.naturalSize)
    let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
    let minimumFrameDuration = try await sourceVideoTrack.load(.minFrameDuration)
    let nominalFrameRate = try await sourceVideoTrack.load(.nominalFrameRate)
    try Task.checkCancellation()

    guard sourceTimeRange.duration.isValid, sourceTimeRange.duration > .zero else {
      throw MotionBlurError.invalidVideoDuration
    }
    guard
      naturalSize.width.isFinite,
      naturalSize.height.isFinite,
      naturalSize.width > 0,
      naturalSize.height > 0
    else {
      throw MotionBlurError.invalidFrameSize(naturalSize)
    }

    let frameDuration = Self.resolveFrameDuration(
      minimumFrameDuration: minimumFrameDuration,
      nominalFrameRate: nominalFrameRate
    )
    let neighborOffset = CMTimeMinimum(
      frameDuration,
      sourceTimeRange.duration
    )
    let composition = AVMutableComposition()

    guard
      let currentTrack = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      ),
      let previousTrack = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      ),
      let nextTrack = composition.addMutableTrack(
        withMediaType: .video,
        preferredTrackID: kCMPersistentTrackID_Invalid
      )
    else {
      throw MotionBlurError.cannotCreateCompositionTrack
    }

    try currentTrack.insertTimeRange(
      sourceTimeRange,
      of: sourceVideoTrack,
      at: .zero
    )

    if sourceTimeRange.duration > neighborOffset {
      try previousTrack.insertTimeRange(
        CMTimeRange(
          start: sourceTimeRange.start,
          duration: sourceTimeRange.duration - neighborOffset
        ),
        of: sourceVideoTrack,
        at: neighborOffset
      )
      try nextTrack.insertTimeRange(
        CMTimeRange(
          start: sourceTimeRange.start + neighborOffset,
          duration: sourceTimeRange.duration - neighborOffset
        ),
        of: sourceVideoTrack,
        at: .zero
      )
    }

    // The custom compositor owns spatial orientation for all three raw source
    // buffers. Keep the temporal tracks at identity so the prepared asset does
    // not carry a second display-transform owner beside its video composition.

    try Task.checkCancellation()
    try await Self.copyAudioTracks(
      from: sourceAsset,
      sourceVideoTimeRange: sourceTimeRange,
      to: composition
    )
    try Task.checkCancellation()

    let normalizedNaturalSize = try Self.normalizedPixelSize(naturalSize)
    let sourceGeometry = try Self.resolveGeometry(
      naturalSize: normalizedNaturalSize,
      preferredTransform: preferredTransform
    )
    composition.naturalSize = sourceGeometry.renderSize

    return PreparedMotionBlurSource(
      asset: composition,
      sourceDisplaySize: sourceGeometry.renderSize,
      duration: sourceTimeRange.duration,
      frameDuration: frameDuration,
      previousTrackID: previousTrack.trackID,
      currentTrackID: currentTrack.trackID,
      nextTrackID: nextTrack.trackID,
      naturalSize: naturalSize,
      preferredTransform: preferredTransform
    )
  }

  /// Creates a fresh render policy for an already prepared temporal source.
  ///
  /// `.currentFrame` asks AVFoundation for only the current track and bypasses
  /// VideoToolbox. `.opticalFlow` references the same asset topology and reads
  /// its live strength source once for each compositor request.
  public func makeVideoComposition(
    source: PreparedMotionBlurSource,
    mode: MotionBlurRenderingMode,
    renderTarget: MotionBlurRenderTarget,
    outputColorSpace: CGColorSpace? = nil,
    postProcessor: @escaping PostProcessor
  ) throws -> AVMutableVideoComposition {
    if case .opticalFlow = mode {
      guard MotionBlurAvailability.isSupported else {
        throw MotionBlurError.unavailable
      }
    }

    let geometry = try Self.resolveFrameGeometry(
      naturalSize: source.naturalSize,
      preferredTransform: source.preferredTransform,
      renderTarget: renderTarget
    )
    let neighborOffset = CMTimeMinimum(
      source.frameDuration,
      source.duration
    )
    let instructions = Self.makeInstructions(
      duration: source.duration,
      neighborOffset: neighborOffset,
      previousTrackID: source.previousTrackID,
      currentTrackID: source.currentTrackID,
      nextTrackID: source.nextTrackID,
      mode: mode,
      quality: quality,
      allowsRealtimeFrameDropping: allowsRealtimeFrameDropping,
      geometry: geometry,
      ciContext: ciContext,
      outputColorSpace: outputColorSpace,
      postProcessor: postProcessor
    )

    let videoComposition = AVMutableVideoComposition()
    videoComposition.customVideoCompositorClass = MotionBlurVideoCompositor.self
    videoComposition.instructions = instructions
    videoComposition.frameDuration = source.frameDuration
    videoComposition.sourceTrackIDForFrameTiming =
      Self.sourceTrackIDForFrameTiming(
        mode: mode,
        currentTrackID: source.currentTrackID
      )
    videoComposition.renderSize = geometry.compositionRenderSize
    videoComposition.renderScale = 1
    return videoComposition
  }

  /// Selects source-authored timing only when temporal neighbors are unused.
  static func sourceTrackIDForFrameTiming(
    mode: MotionBlurRenderingMode,
    currentTrackID: CMPersistentTrackID
  ) -> CMPersistentTrackID {
    switch mode {
    case .currentFrame:
      // Bypass Preview retains the source's authored variable frame timing.
      return currentTrackID
    case .opticalFlow:
      // Optical Flow requires equally spaced temporal samples. Do not preserve
      // a VFR track's irregular times while labeling neighbors as t±d.
      return kCMPersistentTrackID_Invalid
    }
  }

  static func resolveFrameDuration(
    minimumFrameDuration: CMTime,
    nominalFrameRate: Float
  ) -> CMTime {
    let isMinimumDurationUsable =
      minimumFrameDuration.isValid
      && minimumFrameDuration.isNumeric
      && minimumFrameDuration > .zero
      && minimumFrameDuration.seconds.isFinite
    let nominalDuration: CMTime? = {
      guard nominalFrameRate.isFinite, nominalFrameRate > 0 else {
        return nil
      }
      let nominalDuration = CMTime(
        seconds: 1 / Double(nominalFrameRate),
        preferredTimescale: 60_000
      )
      guard
        nominalDuration.isNumeric,
        nominalDuration > .zero,
        nominalDuration.seconds.isFinite
      else {
        return nil
      }
      return nominalDuration
    }()

    if let nominalDuration {
      if isMinimumDurationUsable {
        let relativeDifference =
          abs(minimumFrameDuration.seconds - nominalDuration.seconds)
          / nominalDuration.seconds
        if relativeDifference <= 0.005 {
          // Keep exact rates such as 1001/30000 when the track provides them.
          return minimumFrameDuration
        }
      }
      return nominalDuration
    }
    if isMinimumDurationUsable {
      return minimumFrameDuration
    }
    return CMTime(value: 1, timescale: 30)
  }

  private static func copyAudioTracks(
    from sourceAsset: AVAsset,
    sourceVideoTimeRange: CMTimeRange,
    to composition: AVMutableComposition
  ) async throws {
    for sourceAudioTrack in try await sourceAsset.loadTracks(withMediaType: .audio) {
      try Task.checkCancellation()
      let audioTimeRange = try await sourceAudioTrack.load(.timeRange)
      let intersection = CMTimeRangeGetIntersection(
        audioTimeRange,
        otherRange: sourceVideoTimeRange
      )
      guard intersection.isValid, intersection.duration > .zero else {
        continue
      }

      guard
        let destinationTrack = composition.addMutableTrack(
          withMediaType: .audio,
          preferredTrackID: kCMPersistentTrackID_Invalid
        )
      else {
        throw MotionBlurError.cannotCreateCompositionTrack
      }
      try destinationTrack.insertTimeRange(
        intersection,
        of: sourceAudioTrack,
        at: intersection.start - sourceVideoTimeRange.start
      )
    }
  }

  /// Resolves an AVFoundation track transform for Core Image rendering.
  ///
  /// Track transforms use an upper-left origin, while `CIImage` affine
  /// transforms use a lower-left origin. Converting both the source and
  /// destination coordinate spaces prevents 90-degree portrait transforms from
  /// becoming a visually inverted rotation.
  static func resolveGeometry(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform
  ) throws -> (renderSize: CGSize, coreImageTransform: CGAffineTransform) {
    let sourceRect = CGRect(origin: .zero, size: naturalSize)
    let transformedRect = sourceRect.applying(preferredTransform)
    let renderSize = CGSize(
      width: abs(transformedRect.width).rounded(),
      height: abs(transformedRect.height).rounded()
    )
    guard
      renderSize.width.isFinite,
      renderSize.height.isFinite,
      renderSize.width > 0,
      renderSize.height > 0
    else {
      throw MotionBlurError.invalidFrameSize(renderSize)
    }

    let normalizedAVFoundationTransform = preferredTransform.concatenating(
      CGAffineTransform(
        translationX: -transformedRect.minX,
        y: -transformedRect.minY
      )
    )
    let sourceCoordinateFlip = CGAffineTransform(
      a: 1,
      b: 0,
      c: 0,
      d: -1,
      tx: 0,
      ty: naturalSize.height
    )
    let destinationCoordinateFlip = CGAffineTransform(
      a: 1,
      b: 0,
      c: 0,
      d: -1,
      tx: 0,
      ty: renderSize.height
    )
    let coreImageTransform =
      sourceCoordinateFlip
      .concatenating(normalizedAVFoundationTransform)
      .concatenating(destinationCoordinateFlip)

    return (renderSize, coreImageTransform)
  }

  /// Resolves source, processor, and display geometry without conflating their
  /// coordinate spaces.
  ///
  /// VideoToolbox accepts a maximum working shape of 4096×2160. A file that
  /// physically stores portrait pixels can still fit that limit after an
  /// internal quarter-turn, which is reversed before the display transform is
  /// applied. The quarter-turn is an implementation detail and never changes
  /// the composition's visible orientation.
  static func resolveFrameGeometry(
    naturalSize: CGSize,
    preferredTransform: CGAffineTransform,
    renderTarget: MotionBlurRenderTarget
  ) throws -> MotionBlurFrameGeometry {
    let sourceEncodedSize = try normalizedPixelSize(naturalSize)
    let sourceDisplayGeometry = try resolveGeometry(
      naturalSize: sourceEncodedSize,
      preferredTransform: preferredTransform
    )
    let sourceDisplaySize = sourceDisplayGeometry.renderSize

    let candidateEncodedSize: CGSize
    switch renderTarget {
    case .source:
      candidateEncodedSize = sourceEncodedSize

    case .fitWithin(let maximumPixelSize):
      guard
        maximumPixelSize.width.isFinite,
        maximumPixelSize.height.isFinite,
        maximumPixelSize.width >= 2,
        maximumPixelSize.height >= 2
      else {
        throw MotionBlurError.invalidFrameSize(maximumPixelSize)
      }
      let scale = min(
        1,
        maximumPixelSize.width / sourceDisplaySize.width,
        maximumPixelSize.height / sourceDisplaySize.height
      )
      candidateEncodedSize = evenPixelSize(
        CGSize(
          width: sourceEncodedSize.width * scale,
          height: sourceEncodedSize.height * scale
        )
      )
    }

    let candidateDisplayGeometry = try resolveGeometry(
      naturalSize: candidateEncodedSize,
      preferredTransform: preferredTransform
    )
    let sourceScale = CGAffineTransform(
      scaleX: candidateEncodedSize.width / sourceEncodedSize.width,
      y: candidateEncodedSize.height / sourceEncodedSize.height
    )

    let processorLimit = CGSize(width: 4_096, height: 2_160)
    let processorInputSize: CGSize
    let canonicalTransform: CGAffineTransform
    if candidateEncodedSize.fits(within: processorLimit) {
      processorInputSize = candidateEncodedSize
      canonicalTransform = .identity
    } else {
      let rotatedSize = CGSize(
        width: candidateEncodedSize.height,
        height: candidateEncodedSize.width
      )
      guard rotatedSize.fits(within: processorLimit) else {
        throw MotionBlurError.unsupportedFrameSize(
          width: Int(candidateEncodedSize.width),
          height: Int(candidateEncodedSize.height)
        )
      }
      processorInputSize = rotatedSize
      canonicalTransform = normalizedCoreImageTransform(
        naturalSize: candidateEncodedSize,
        // Use an exact orthogonal matrix. `rotationAngle:` introduces tiny
        // cosine residues that can expand a pixel extent fractionally.
        transform: CGAffineTransform(
          a: 0,
          b: 1,
          c: -1,
          d: 0,
          tx: 0,
          ty: 0
        )
      )
    }

    let sourceToProcessorTransform = sourceScale.concatenating(
      canonicalTransform
    )
    let processorToRenderTransform =
      canonicalTransform
      .inverted()
      .concatenating(candidateDisplayGeometry.coreImageTransform)

    return MotionBlurFrameGeometry(
      sourceEncodedSize: sourceEncodedSize,
      sourceDisplaySize: sourceDisplaySize,
      processorInputSize: processorInputSize,
      compositionRenderSize: candidateDisplayGeometry.renderSize,
      sourceToProcessorTransform: sourceToProcessorTransform,
      processorToRenderTransform: processorToRenderTransform,
      usesSourceBuffersDirectly:
        sourceToProcessorTransform.isIdentity
        && processorInputSize == sourceEncodedSize
    )
  }

  private static func normalizedPixelSize(_ size: CGSize) throws -> CGSize {
    let normalized = CGSize(
      width: size.width.rounded(),
      height: size.height.rounded()
    )
    guard
      normalized.width.isFinite,
      normalized.height.isFinite,
      normalized.width > 0,
      normalized.height > 0
    else {
      throw MotionBlurError.invalidFrameSize(size)
    }
    return normalized
  }

  /// Produces positive even dimensions for a hardware processing buffer.
  ///
  /// Flooring ensures a viewport is never exceeded. The two-pixel minimum
  /// avoids collapsing a very small but otherwise valid layout measurement.
  private static func evenPixelSize(_ size: CGSize) -> CGSize {
    func evenFloor(_ value: CGFloat) -> CGFloat {
      max(2, floor(value / 2) * 2)
    }
    return CGSize(
      width: evenFloor(size.width),
      height: evenFloor(size.height)
    )
  }

  /// Normalizes a Core Image transform so its transformed extent starts at
  /// zero, independent of rotation direction.
  private static func normalizedCoreImageTransform(
    naturalSize: CGSize,
    transform: CGAffineTransform
  ) -> CGAffineTransform {
    let transformedExtent = CGRect(
      origin: .zero,
      size: naturalSize
    )
    .applying(transform)
    return transform.concatenating(
      CGAffineTransform(
        translationX: -transformedExtent.minX,
        y: -transformedExtent.minY
      )
    )
  }

  private static func makeInstructions(
    duration: CMTime,
    neighborOffset: CMTime,
    previousTrackID: CMPersistentTrackID,
    currentTrackID: CMPersistentTrackID,
    nextTrackID: CMPersistentTrackID,
    mode: MotionBlurRenderingMode,
    quality: MotionBlurQuality,
    allowsRealtimeFrameDropping: Bool,
    geometry: MotionBlurFrameGeometry,
    ciContext: CIContext,
    outputColorSpace: CGColorSpace?,
    postProcessor: @escaping PostProcessor
  ) -> [MotionBlurCompositionInstruction] {
    if case .currentFrame = mode {
      return [
        MotionBlurCompositionInstruction(
          timeRange: CMTimeRange(start: .zero, duration: duration),
          previousTrackID: nil,
          currentTrackID: currentTrackID,
          nextTrackID: nil,
          renderingMode: mode,
          quality: quality,
          allowsRealtimeFrameDropping: allowsRealtimeFrameDropping,
          frameDuration: neighborOffset,
          geometry: geometry,
          ciContext: ciContext,
          outputColorSpace: outputColorSpace,
          postProcessor: postProcessor
        )
      ]
    }

    let finalNextTime = CMTimeMaximum(.zero, duration - neighborOffset)
    let boundaries = [.zero, neighborOffset, finalNextTime, duration]
      .filter { $0 >= .zero && $0 <= duration }
      .sorted()
      .reduce(into: [CMTime]()) { result, value in
        if result.last != value {
          result.append(value)
        }
      }

    return zip(boundaries, boundaries.dropFirst()).compactMap { start, end in
      let segmentDuration = end - start
      guard segmentDuration > .zero else { return nil }
      let hasPrevious = start >= neighborOffset
      let hasNext = end <= finalNextTime
      return MotionBlurCompositionInstruction(
        timeRange: CMTimeRange(start: start, duration: segmentDuration),
        previousTrackID: hasPrevious ? previousTrackID : nil,
        currentTrackID: currentTrackID,
        nextTrackID: hasNext ? nextTrackID : nil,
        renderingMode: mode,
        quality: quality,
        allowsRealtimeFrameDropping: allowsRealtimeFrameDropping,
        frameDuration: neighborOffset,
        geometry: geometry,
        ciContext: ciContext,
        outputColorSpace: outputColorSpace,
        postProcessor: postProcessor
      )
    }
  }
}

extension CGSize {

  fileprivate func fits(within limit: CGSize) -> Bool {
    width <= limit.width && height <= limit.height
  }
}
