//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import CoreImage
import CoreMedia
import Foundation
import VideoToolbox

/// Errors surfaced while exporting a video.
nonisolated enum VideoExportError: LocalizedError {
  case missingVideoTrack
  case invalidSourceBitRate(Float)
  case unsupportedVideoSettings
  case cannotAttachReaderOutput(AVMediaType)
  case cannotAttachWriterInput(AVMediaType)
  case missingAudioFormatDescription
  case failed(String)

  var errorDescription: String? {
    switch self {
    case .missingVideoTrack:
      return "The selected file does not contain a video track."
    case .invalidSourceBitRate(let bitRate):
      return "The source video bitrate is unavailable or unsupported (\(bitRate) bps)."
    case .unsupportedVideoSettings:
      return "This device cannot encode HEVC with the source video's settings."
    case .cannotAttachReaderOutput(let mediaType):
      return "Could not read the source \(mediaType.exportDisplayName) track."
    case .cannotAttachWriterInput(let mediaType):
      return "Could not write the output \(mediaType.exportDisplayName) track."
    case .missingAudioFormatDescription:
      return "Could not preserve the source audio format."
    case .failed(let message):
      return message
    }
  }
}

/// Renders one immutable Färg recipe over a video and writes a new file.
///
/// The export implementation stays behind this protocol so UI and background
/// orchestration do not own codec or media-pipeline details.
nonisolated protocol VideoExporting: Sendable {
  func export(
    asset: AVAsset,
    recipe: FargVideoRenderRecipe,
    colorInfo: VideoColorInfo,
    to outputURL: URL,
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws
}

/// Default exporter: applies the parametric composition while encoding HEVC.
///
/// The video writer keeps the source render extent and uses the source video
/// track's estimated data rate as its average bitrate target. LUT-only recipes
/// retain source sample timing; Optical Flow recipes use the nominal fixed
/// cadence required by their equally spaced temporal samples. Audio tracks are
/// remuxed without re-encoding.
nonisolated struct ParametricVideoExporter: VideoExporting {

  var ciContext: CIContext = FargCIContext.shared

  func export(
    asset: AVAsset,
    recipe: FargVideoRenderRecipe,
    colorInfo: VideoColorInfo,
    to outputURL: URL,
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws {

    let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
    guard let primaryVideoTrack = sourceVideoTracks.first else {
      throw VideoExportError.missingVideoTrack
    }

    let prepared = try await FargVideoRenderPipeline(
      ciContext: ciContext
    )
    .prepare(
      asset: asset,
      recipe: recipe,
      colorInfo: colorInfo,
      purpose: .export
    )
    let renderAsset = prepared.asset
    let composition = prepared.videoComposition
    let renderVideoTracks = try await renderAsset.loadTracks(withMediaType: .video)
    guard let primaryRenderVideoTrack = renderVideoTracks.first else {
      throw VideoExportError.missingVideoTrack
    }

    let renderVideoTimeRange = try await primaryRenderVideoTrack.load(.timeRange)
    let sourceBitRate = try await primaryVideoTrack.load(.estimatedDataRate)
    let encoding = try SourceVideoEncoding(
      renderSize: composition.renderSize,
      sourceBitRate: sourceBitRate,
      colorInfo: colorInfo
    )

    try? FileManager.default.removeItem(at: outputURL)

    let reader = try AVAssetReader(asset: renderAsset)
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    let cancellationHandle = AssetExportCancellationHandle(
      reader: reader,
      writer: writer
    )
    var didCompleteWriting = false
    defer {
      if didCompleteWriting == false {
        reader.cancelReading()
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
      }
    }

    let videoOutput = AVAssetReaderVideoCompositionOutput(
      videoTracks: renderVideoTracks,
      videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String:
          Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
      ]
    )
    videoOutput.videoComposition = composition
    guard reader.canAdd(videoOutput) else {
      throw VideoExportError.cannotAttachReaderOutput(.video)
    }
    let videoProvider = reader.outputProvider(for: videoOutput)

    let videoSettings = encoding.outputSettings
    guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
      throw VideoExportError.unsupportedVideoSettings
    }
    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: videoSettings
    )
    videoInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput) else {
      throw VideoExportError.cannotAttachWriterInput(.video)
    }
    let videoReceiver = writer.inputReceiver(for: videoInput)
    let videoTransfer = AssetSampleTransfer(
      provider: videoProvider,
      receiver: videoReceiver
    )

    var audioTransfers: [AssetSampleTransfer] = []
    for audioTrack in try await renderAsset.loadTracks(withMediaType: .audio) {
      let audioOutput = AVAssetReaderTrackOutput(
        track: audioTrack,
        outputSettings: nil
      )
      guard reader.canAdd(audioOutput) else {
        throw VideoExportError.cannotAttachReaderOutput(.audio)
      }
      let audioProvider = reader.outputProvider(for: audioOutput)

      guard let sourceFormatHint = try await audioTrack.load(.formatDescriptions).first else {
        throw VideoExportError.missingAudioFormatDescription
      }
      let audioInput = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: nil,
        sourceFormatHint: sourceFormatHint
      )
      audioInput.expectsMediaDataInRealTime = false
      guard writer.canAdd(audioInput) else {
        throw VideoExportError.cannotAttachWriterInput(.audio)
      }
      let audioReceiver = writer.inputReceiver(for: audioInput)
      audioTransfers.append(
        AssetSampleTransfer(
          provider: audioProvider,
          receiver: audioReceiver
        )
      )
    }

    try writer.start()
    writer.startSession(atSourceTime: .zero)
    try reader.start()

    try await withTaskCancellationHandler {
      do {
        let videoTimeline = try await withThrowingTaskGroup(
          of: AssetSampleTimeline?.self
        ) { group in
          group.addTask {
            try await videoTransfer.transfer { presentationTime in
              let durationSeconds = renderVideoTimeRange.duration.seconds
              guard durationSeconds.isFinite, durationSeconds > 0 else { return }
              let elapsed = presentationTime - renderVideoTimeRange.start
              let fraction = elapsed.seconds / durationSeconds
              onProgress(min(max(fraction, 0), 0.999))
            }
          }

          for transfer in audioTransfers {
            group.addTask {
              _ = try await transfer.transfer()
              return nil
            }
          }

          var videoTimeline: AssetSampleTimeline?
          for try await timeline in group {
            if let timeline {
              videoTimeline = timeline
            }
          }
          guard let videoTimeline else {
            throw VideoExportError.failed("Video transfer ended without a result.")
          }
          return videoTimeline
        }

        try videoTimeline.validateVideoCoverage(
          expectedDuration: renderVideoTimeRange.duration,
          nominalFrameDuration: composition.frameDuration
        )
        cancellationHandle.markTransfersFinished()
      } catch {
        reader.cancelReading()
        try Task.checkCancellation()
        throw error
      }

      switch reader.status {
      case .completed:
        break
      case .cancelled:
        throw CancellationError()
      case .failed:
        throw reader.error ?? VideoExportError.failed("Video reading failed.")
      case .unknown, .reading:
        throw VideoExportError.failed("Video reading ended before completion.")
      @unknown default:
        throw VideoExportError.failed("Video reading ended in an unknown state.")
      }

      try Task.checkCancellation()
      await writer.finishWriting()
      try Task.checkCancellation()
      guard writer.status == .completed else {
        throw writer.error ?? VideoExportError.failed("Video writing failed.")
      }
      try await validateWrittenVideoCoverage(
        at: outputURL,
        expectedDuration: renderVideoTimeRange.duration,
        nominalFrameDuration: composition.frameDuration
      )
      try Task.checkCancellation()
    } onCancel: {
      cancellationHandle.cancel()
    }

    didCompleteWriting = true
    onProgress(1.0)
  }

  /// Verifies the finalized container before it is eligible for Photos import.
  ///
  /// Reader completion proves that its outputs reached EOF, but does not prove
  /// that the finalized output retained the source video's complete time range.
  private func validateWrittenVideoCoverage(
    at outputURL: URL,
    expectedDuration: CMTime,
    nominalFrameDuration: CMTime
  ) async throws {
    let writtenAsset = AVURLAsset(url: outputURL)
    let writtenVideoTracks = try await writtenAsset.loadTracks(withMediaType: .video)
    guard let writtenVideoTrack = writtenVideoTracks.first else {
      throw VideoExportError.missingVideoTrack
    }
    let writtenVideoTimeRange = try await writtenVideoTrack.load(.timeRange)
    let tolerance = AssetSampleTimeline.coverageTolerance(
      nominalFrameDuration: nominalFrameDuration
    )

    guard
      AssetSampleTimeline.isPositiveNumeric(expectedDuration),
      AssetSampleTimeline.isPositiveNumeric(writtenVideoTimeRange.duration),
      writtenVideoTimeRange.duration + tolerance >= expectedDuration
    else {
      throw VideoExportError.failed(
        "The exported movie ended before the final video frame."
      )
    }
  }
}

/// Source-derived settings for the HEVC encoder.
///
/// `estimatedDataRate` is the closest source-side representation of the
/// original encoder's average bitrate. AVFoundation exposes no lossless
/// conversion from an arbitrary source codec's complete encoder configuration
/// to HEVC settings.
private nonisolated struct SourceVideoEncoding {
  let width: Int
  let height: Int
  let averageBitRate: Int
  let colorInfo: VideoColorInfo

  init(
    renderSize: CGSize,
    sourceBitRate: Float,
    colorInfo: VideoColorInfo
  ) throws {
    guard
      renderSize.width.isFinite,
      renderSize.height.isFinite,
      renderSize.width > 0,
      renderSize.height > 0
    else {
      throw VideoExportError.failed("The source video resolution is invalid.")
    }
    guard
      sourceBitRate.isFinite,
      sourceBitRate > 0,
      sourceBitRate <= Float(Int32.max)
    else {
      throw VideoExportError.invalidSourceBitRate(sourceBitRate)
    }

    self.width = Int(renderSize.width.rounded())
    self.height = Int(renderSize.height.rounded())
    self.averageBitRate = Int(sourceBitRate.rounded())
    self.colorInfo = colorInfo.isHDR ? .sdrRec709 : colorInfo
  }

  var outputSettings: [String: Any] {
    [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey:
          colorInfo.colorPrimaries ?? AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey:
          colorInfo.transferFunction ?? AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey:
          colorInfo.yCbCrMatrix ?? AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
      AVVideoCompressionPropertiesKey: [
        kVTCompressionPropertyKey_AverageBitRate as String: averageBitRate,
        kVTCompressionPropertyKey_ProfileLevel as String:
          kVTProfileLevel_HEVC_Main_AutoLevel,
      ],
    ]
  }
}

/// A single reader-provider to writer-receiver stream.
///
/// The modern provider/receiver APIs serialize backpressure in `append(_:)`.
/// Each instance is moved into exactly one child task; this unchecked boundary
/// only bridges the Objective-C reference types that do not declare Sendable.
private nonisolated struct AssetSampleTransfer: @unchecked Sendable {
  let provider:
    AVAssetReaderOutput.Provider<
      CMReadySampleBuffer<CMSampleBuffer.DynamicContent>
    >
  let receiver: AVAssetWriterInput.SampleBufferReceiver

  func transfer(
    onSample: (@Sendable (CMTime) -> Void)? = nil
  ) async throws -> AssetSampleTimeline {
    defer { receiver.finish() }

    var timeline = AssetSampleTimeline()
    while let sampleBuffer = try await provider.next() {
      try Task.checkCancellation()
      try await receiver.append(sampleBuffer)
      timeline.record(
        presentationTime: sampleBuffer.presentationTimeStamp,
        duration: sampleBuffer.duration
      )
      if let onSample {
        onSample(sampleBuffer.presentationTimeStamp)
      }
    }
    return timeline
  }
}

/// The presentation-time coverage observed while transferring one media stream.
///
/// Keeping this summary beside the transfer prevents an orderly reader EOF from
/// being mistaken for a complete video when another stream, such as audio,
/// continues to the intended end of the movie.
private nonisolated struct AssetSampleTimeline: Sendable {
  private(set) var sampleCount = 0
  private(set) var firstPresentationTime: CMTime?
  private(set) var lastPresentationTime: CMTime?
  private(set) var lastSampleDuration: CMTime?
  private(set) var inferredLastSampleDuration: CMTime?
  private(set) var hasStrictlyIncreasingPresentationTimes = true

  mutating func record(
    presentationTime: CMTime,
    duration: CMTime
  ) {
    if firstPresentationTime == nil {
      firstPresentationTime = presentationTime
    }
    if let previousPresentationTime = lastPresentationTime {
      let interval = presentationTime - previousPresentationTime
      if Self.isPositiveNumeric(interval) {
        inferredLastSampleDuration = interval
      } else {
        hasStrictlyIncreasingPresentationTimes = false
      }
    }

    sampleCount += 1
    lastPresentationTime = presentationTime
    lastSampleDuration = duration
  }

  /// Rejects an empty, disordered, or prematurely ended video timeline.
  ///
  /// Variable-frame-rate samples retain their authored durations. If the final
  /// sample omits a usable duration, the most recent presentation-time interval
  /// is preferred, then the composition cadence is used as a final fallback.
  func validateVideoCoverage(
    expectedDuration: CMTime,
    nominalFrameDuration: CMTime
  ) throws {
    guard
      sampleCount > 0,
      hasStrictlyIncreasingPresentationTimes,
      let firstPresentationTime,
      let lastPresentationTime,
      Self.isNumeric(firstPresentationTime),
      Self.isNumeric(lastPresentationTime),
      Self.isPositiveNumeric(expectedDuration)
    else {
      throw VideoExportError.failed(
        "Video reading ended without a valid presentation timeline."
      )
    }

    let tailDuration: CMTime
    if let lastSampleDuration, Self.isPositiveNumeric(lastSampleDuration) {
      tailDuration = lastSampleDuration
    } else if let inferredLastSampleDuration,
      Self.isPositiveNumeric(inferredLastSampleDuration)
    {
      tailDuration = inferredLastSampleDuration
    } else if Self.isPositiveNumeric(nominalFrameDuration) {
      tailDuration = nominalFrameDuration
    } else {
      throw VideoExportError.failed(
        "The final video sample has no usable duration."
      )
    }

    let coveredDuration =
      lastPresentationTime + tailDuration - firstPresentationTime
    guard Self.isPositiveNumeric(coveredDuration) else {
      throw VideoExportError.failed(
        "Video reading produced an invalid presentation duration."
      )
    }

    let tolerance = Self.coverageTolerance(
      nominalFrameDuration: nominalFrameDuration,
      fallback: tailDuration
    )
    guard coveredDuration + tolerance >= expectedDuration else {
      throw VideoExportError.failed(
        "Video reading ended before the final frame was rendered."
      )
    }
  }

  fileprivate static func coverageTolerance(
    nominalFrameDuration: CMTime,
    fallback: CMTime = CMTime(value: 1, timescale: 30)
  ) -> CMTime {
    if isPositiveNumeric(nominalFrameDuration) {
      return nominalFrameDuration
    }
    if isPositiveNumeric(fallback) {
      return fallback
    }
    return CMTime(value: 1, timescale: 30)
  }

  fileprivate static func isNumeric(_ time: CMTime) -> Bool {
    time.isValid
      && time.isNumeric
      && time.seconds.isFinite
  }

  fileprivate static func isPositiveNumeric(_ time: CMTime) -> Bool {
    isNumeric(time) && time > .zero
  }
}

/// Sendable cancellation access to an in-flight reader and writer.
///
/// Writer cancellation is deferred until every input transfer has finished, so
/// it never races an in-flight `append(_:)`. The cancelled state is sticky to
/// cover cancellation between transfer completion and `finishWriting()`.
private nonisolated final class AssetExportCancellationHandle: @unchecked Sendable {
  private let lock = NSLock()
  private let reader: AVAssetReader
  private let writer: AVAssetWriter
  private var isCancelled = false
  private var didFinishTransfers = false

  init(
    reader: AVAssetReader,
    writer: AVAssetWriter
  ) {
    self.reader = reader
    self.writer = writer
  }

  func markTransfersFinished() {
    lock.lock()
    didFinishTransfers = true
    let shouldCancelWriter = isCancelled
    lock.unlock()

    if shouldCancelWriter {
      writer.cancelWriting()
    }
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let canCancelWriter = didFinishTransfers
    lock.unlock()

    reader.cancelReading()
    if canCancelWriter {
      writer.cancelWriting()
    }
  }
}

extension AVMediaType {
  fileprivate nonisolated var exportDisplayName: String {
    if self == .video {
      return "video"
    }
    if self == .audio {
      return "audio"
    }
    return rawValue
  }
}
