//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import CoreImage
import Foundation

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
  case cannotWrapPixelBuffer
  case cannotCreateParameters

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
        "Optical Flow motion blur supports source frames up to 4096×2160; "
        + "this video is \(width)×\(height)."
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
    case .cannotWrapPixelBuffer:
      return "Färg couldn't prepare an IOSurface-backed video frame."
    case .cannotCreateParameters:
      return "Färg couldn't configure motion blur for this frame."
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

/// Builds the multi-track input required by an `AVVideoCompositing` temporal
/// effect.
///
/// The source movie is copied into three composition tracks at equal temporal
/// offsets around each output frame. A fixed nominal cadence gives VideoToolbox
/// honest t-d, t, and t+d timestamps even when the source movie is variable
/// frame rate. The caller's `postProcessor` runs after motion blur, which lets
/// Färg apply its Brightroom parametric LUT in the same composition pass.
public struct MotionBlurVideoCompositionBuilder: Sendable {

  public typealias PostProcessor =
    @Sendable (_ motionBlurredImage: CIImage, _ renderExtent: CGRect) throws -> CIImage

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
    postProcessor: @escaping PostProcessor
  ) async throws -> PreparedMotionBlurVideo {
    guard settings.isEnabled else {
      preconditionFailure("Use the ordinary single-frame renderer when motion blur is disabled.")
    }
    guard MotionBlurAvailability.isSupported else {
      throw MotionBlurError.unavailable
    }
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

    let frameWidth = Int(naturalSize.width.rounded())
    let frameHeight = Int(naturalSize.height.rounded())
    guard frameWidth <= 4096, frameHeight <= 2160 else {
      throw MotionBlurError.unsupportedFrameSize(
        width: frameWidth,
        height: frameHeight
      )
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

    let geometry = try Self.resolveGeometry(
      naturalSize: naturalSize,
      preferredTransform: preferredTransform
    )
    composition.naturalSize = geometry.renderSize

    let instructions = Self.makeInstructions(
      duration: sourceTimeRange.duration,
      neighborOffset: neighborOffset,
      previousTrackID: previousTrack.trackID,
      currentTrackID: currentTrack.trackID,
      nextTrackID: nextTrack.trackID,
      settings: settings,
      quality: quality,
      allowsRealtimeFrameDropping: allowsRealtimeFrameDropping,
      sourceTransform: geometry.coreImageTransform,
      renderSize: geometry.renderSize,
      ciContext: ciContext,
      postProcessor: postProcessor
    )

    let videoComposition = AVMutableVideoComposition()
    videoComposition.customVideoCompositorClass = MotionBlurVideoCompositor.self
    videoComposition.instructions = instructions
    videoComposition.frameDuration = frameDuration
    // Optical Flow requires equally spaced temporal samples. Do not preserve a
    // VFR track's irregular request times while labeling its neighbors as t±d.
    videoComposition.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
    videoComposition.renderSize = geometry.renderSize
    videoComposition.renderScale = 1

    return PreparedMotionBlurVideo(
      asset: composition,
      videoComposition: videoComposition
    )
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

  private static func makeInstructions(
    duration: CMTime,
    neighborOffset: CMTime,
    previousTrackID: CMPersistentTrackID,
    currentTrackID: CMPersistentTrackID,
    nextTrackID: CMPersistentTrackID,
    settings: MotionBlurSettings,
    quality: MotionBlurQuality,
    allowsRealtimeFrameDropping: Bool,
    sourceTransform: CGAffineTransform,
    renderSize: CGSize,
    ciContext: CIContext,
    postProcessor: @escaping PostProcessor
  ) -> [MotionBlurCompositionInstruction] {
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
        settings: settings,
        quality: quality,
        allowsRealtimeFrameDropping: allowsRealtimeFrameDropping,
        frameDuration: neighborOffset,
        sourceTransform: sourceTransform,
        renderExtent: CGRect(origin: .zero, size: renderSize),
        ciContext: ciContext,
        postProcessor: postProcessor
      )
    }
  }
}
