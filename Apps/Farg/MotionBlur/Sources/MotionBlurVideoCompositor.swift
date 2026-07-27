//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import VideoToolbox

/// Decoder formats Färg can preserve until its own source-to-processor render.
///
/// Apple Log is commonly decoded from ProRes as 10-bit 4:2:2, while HEVC
/// sources are commonly 4:2:0. Advertising both families is required for
/// `canConformColorOfSourceFrames` to prevent an implicit conversion into the
/// composition's Rec.709 output space.
private let motionBlurAcceptedSourcePixelFormats: [OSType] = [
  kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
  kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
  kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
  kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
  kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
  kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
  kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
  kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
  kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange,
  kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
  kCVPixelFormatType_32BGRA,
  kCVPixelFormatType_64RGBAHalf,
]

/// The immutable instruction consumed by `MotionBlurVideoCompositor`.
final class MotionBlurCompositionInstruction:
  NSObject,
  AVVideoCompositionInstructionProtocol,
  @unchecked Sendable
{

  typealias PostProcessor = MotionBlurVideoCompositionBuilder.PostProcessor

  let timeRange: CMTimeRange
  let enablePostProcessing = false
  let containsTweening = true
  let passthroughTrackID = kCMPersistentTrackID_Invalid
  let requiredSourceTrackIDs: [NSValue]?

  let previousTrackID: CMPersistentTrackID?
  let currentTrackID: CMPersistentTrackID
  let nextTrackID: CMPersistentTrackID?
  let renderingMode: MotionBlurRenderingMode
  let quality: MotionBlurQuality
  let allowsRealtimeFrameDropping: Bool
  let frameDuration: CMTime
  let geometry: MotionBlurFrameGeometry
  let ciContext: CIContext

  /// The destination color space for materializing the final pixel buffer.
  ///
  /// This is intentionally independent of both the decoded source frame and
  /// the mastering space used to interpret `postProcessor` output. A caller
  /// can therefore preserve source delivery or encode a separate display
  /// delivery transform after its LUT has evaluated wide-gamut source pixels.
  let outputColorSpace: CGColorSpace?

  let postProcessor: PostProcessor

  var renderExtent: CGRect {
    CGRect(origin: .zero, size: geometry.compositionRenderSize)
  }

  init(
    timeRange: CMTimeRange,
    previousTrackID: CMPersistentTrackID?,
    currentTrackID: CMPersistentTrackID,
    nextTrackID: CMPersistentTrackID?,
    renderingMode: MotionBlurRenderingMode,
    quality: MotionBlurQuality,
    allowsRealtimeFrameDropping: Bool,
    frameDuration: CMTime,
    geometry: MotionBlurFrameGeometry,
    ciContext: CIContext,
    outputColorSpace: CGColorSpace? = nil,
    postProcessor: @escaping PostProcessor
  ) {
    let resolvedPreviousTrackID: CMPersistentTrackID?
    let resolvedNextTrackID: CMPersistentTrackID?
    switch renderingMode {
    case .currentFrame:
      resolvedPreviousTrackID = nil
      resolvedNextTrackID = nil
    case .opticalFlow:
      resolvedPreviousTrackID = previousTrackID
      resolvedNextTrackID = nextTrackID
    }

    self.timeRange = timeRange
    self.previousTrackID = resolvedPreviousTrackID
    self.currentTrackID = currentTrackID
    self.nextTrackID = resolvedNextTrackID
    self.renderingMode = renderingMode
    self.quality = quality
    self.allowsRealtimeFrameDropping = allowsRealtimeFrameDropping
    self.frameDuration = frameDuration
    self.geometry = geometry
    self.ciContext = ciContext
    self.outputColorSpace = outputColorSpace
    self.postProcessor = postProcessor
    self.requiredSourceTrackIDs = [
      resolvedPreviousTrackID,
      currentTrackID,
      resolvedNextTrackID,
    ]
    .compactMap { $0 }
    .map { NSNumber(value: $0) }
    super.init()
  }
}

/// AVFoundation custom compositor backed by VideoToolbox's Optical Flow motion
/// blur processor.
///
/// AVFoundation may submit requests concurrently. A dedicated serial queue
/// keeps one `VTFrameProcessor` session ordered while playback seeks are marked
/// as random submissions so VideoToolbox can invalidate its temporal cache.
public final class MotionBlurVideoCompositor:
  NSObject,
  AVVideoCompositing,
  @unchecked Sendable
{

  public let sourcePixelBufferAttributes: [String: any Sendable]? = [
    kCVPixelBufferPixelFormatTypeKey as String:
      motionBlurAcceptedSourcePixelFormats.map(Int.init),
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String],
    kCVPixelBufferMetalCompatibilityKey as String: true,
  ]

  public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String],
    kCVPixelBufferMetalCompatibilityKey as String: true,
  ]

  /// Preserve source color until Färg's post-LUT render resolves the output.
  ///
  /// `canConformColorOfSourceFrames` only prevents AVFoundation's conversion
  /// when the decoded format is advertised above. Optical Flow inputs are
  /// converted to its required half-float format inside this compositor so a
  /// Rec.709 output contract never converts Apple Log before the LUT.
  public let supportsWideColorSourceFrames = true
  public let supportsHDRSourceFrames = true
  public let canConformColorOfSourceFrames = true

  private let renderingQueue = DispatchQueue(
    label: "app.muukii.farg.motion-blur-compositor",
    qos: .userInitiated,
    autoreleaseFrequency: .workItem
  )
  private let requestCoordinator = MotionBlurRequestCoordinator()

  #if !targetEnvironment(simulator)
    private var processorSession: MotionBlurProcessorSession?
    private var lastCompositionTime: CMTime?
    private var lastSubmissionGeneration: UInt?
    private let processorSessionResetRegistrationID = UUID()
    private var registeredStrengthSources: [ObjectIdentifier: MotionBlurStrengthSource] = [:]
  #endif

  public override init() {
    super.init()
  }

  deinit {
    #if !targetEnvironment(simulator)
      for source in registeredStrengthSources.values {
        source.unregisterProcessorSessionResetHandler(
          id: processorSessionResetRegistrationID
        )
      }
      processorSession?.end()
    #endif
  }

  public func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
    // AVFoundation can retain this compositor while replacing the composition.
    // End the old temporal session so its Optical Flow cache and IOSurfaces do
    // not outlive the render context that produced them.
    scheduleProcessorSessionReset()
  }

  public func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
    // Registration is synchronous so cancellation cannot overtake a request
    // between its generation capture and its rendering-queue submission.
    let instruction =
      asyncVideoCompositionRequest.videoCompositionInstruction
      as? MotionBlurCompositionInstruction
    let requestMode: MotionBlurRequestCoordinator.Mode =
      instruction?.allowsRealtimeFrameDropping == true
        && asyncVideoCompositionRequest.renderContext.highQualityRendering == false
      ? .realtime
      : .offline
    let registration = requestCoordinator.register(
      asyncVideoCompositionRequest,
      mode: requestMode
    )
    for delivery in registration.supersededDeliveries {
      delivery.request.finishCancelledRequest()
      requestCoordinator.completeSupersededDelivery(delivery.ticket)
    }

    let ticket = registration.ticket
    let requestCoordinator = requestCoordinator
    renderingQueue.async { [weak self] in
      guard let request = requestCoordinator.beginRendering(ticket) else {
        // Cancellation already delivered this queued request's terminal callback.
        return
      }
      guard let self else {
        requestCoordinator.finish(ticket, result: .cancelled)
        return
      }
      guard requestCoordinator.isCurrent(ticket) else {
        requestCoordinator.finish(ticket, result: .cancelled)
        return
      }

      do {
        let outputBuffer = try self.render(
          request: request,
          cancellationTicket: ticket
        )
        requestCoordinator.finish(ticket, result: .frame(outputBuffer))
      } catch is CancellationError {
        requestCoordinator.finish(ticket, result: .cancelled)
      } catch {
        requestCoordinator.finish(ticket, result: .failed(error))
      }
    }
  }

  public func cancelAllPendingVideoCompositionRequests() {
    requestCoordinator.cancelCurrentGenerationAndWait()
    scheduleProcessorSessionReset()
  }

  private func render(
    request: AVAsynchronousVideoCompositionRequest,
    cancellationTicket: MotionBlurRequestCoordinator.Ticket
  ) throws -> CVPixelBuffer {
    guard
      let instruction =
        request.videoCompositionInstruction as? MotionBlurCompositionInstruction
    else {
      throw MotionBlurError.cannotWrapPixelBuffer
    }
    let currentBuffer = try sourceFrame(
      byTrackID: instruction.currentTrackID,
      stage: .currentSource,
      instruction: instruction,
      request: request
    )

    try validateGeometry(
      of: currentBuffer,
      expected: instruction.geometry.sourceEncodedSize,
      stage: .currentSource
    )

    let strengthSource: MotionBlurStrengthSource
    switch instruction.renderingMode {
    case .currentFrame:
      #if !targetEnvironment(simulator)
        // A same-item composition replacement does not necessarily create a
        // new compositor or render context. Release the prior Optical Flow
        // session explicitly when the first bypass request reaches this queue.
        resetProcessorSession()
      #endif
      return try compose(
        imageBuffer: currentBuffer,
        currentBuffer: currentBuffer,
        imageTransform:
          instruction.geometry.sourceToProcessorTransform.concatenating(
            instruction.geometry.processorToRenderTransform
          ),
        instruction: instruction,
        request: request
      )
    case .opticalFlow(let source):
      strengthSource = source
    }

    #if targetEnvironment(simulator)
      throw MotionBlurError.unavailable
    #else
      registerProcessorSessionReset(with: strengthSource)
      let previousBuffer: CVPixelBuffer?
      if let previousTrackID = instruction.previousTrackID {
        previousBuffer = try sourceFrame(
          byTrackID: previousTrackID,
          stage: .previousSource,
          instruction: instruction,
          request: request
        )
      } else {
        previousBuffer = nil
      }
      let nextBuffer: CVPixelBuffer?
      if let nextTrackID = instruction.nextTrackID {
        nextBuffer = try sourceFrame(
          byTrackID: nextTrackID,
          stage: .nextSource,
          instruction: instruction,
          request: request
        )
      } else {
        nextBuffer = nil
      }

      if let previousBuffer {
        try validateGeometry(
          of: previousBuffer,
          expected: instruction.geometry.sourceEncodedSize,
          stage: .previousSource
        )
      }
      if let nextBuffer {
        try validateGeometry(
          of: nextBuffer,
          expected: instruction.geometry.sourceEncodedSize,
          stage: .nextSource
        )
      }

      let sourcePixelFormat = CVPixelBufferGetPixelFormatType(currentBuffer)
      let sourceBuffers = [previousBuffer, currentBuffer, nextBuffer].compactMap { $0 }
      guard
        motionBlurAcceptedSourcePixelFormats.contains(sourcePixelFormat),
        sourceBuffers.allSatisfy({
          motionBlurAcceptedSourcePixelFormats.contains(
            CVPixelBufferGetPixelFormatType($0)
          )
        })
      else {
        throw MotionBlurError.unsupportedPixelFormat(sourcePixelFormat)
      }

      // VideoToolbox rejects a current-only request. A clip with no temporal
      // neighbor cannot acquire motion blur, so render its sole frame through
      // the ordinary transform/LUT path.
      if previousBuffer == nil, nextBuffer == nil {
        return try compose(
          imageBuffer: currentBuffer,
          currentBuffer: currentBuffer,
          imageTransform:
            instruction.geometry.sourceToProcessorTransform.concatenating(
              instruction.geometry.processorToRenderTransform
            ),
          instruction: instruction,
          request: request
        )
      }

      let session = try processorSession(
        width: Int(instruction.geometry.processorInputSize.width),
        height: Int(instruction.geometry.processorInputSize.height),
        sourcePixelFormat: kCVPixelFormatType_64RGBAHalf,
        quality: instruction.quality
      )
      let processorCurrentBuffer = try processorSourceBuffer(
        from: currentBuffer,
        stage: .currentProcessor,
        slot: .current,
        session: session,
        instruction: instruction
      )
      let processorPreviousBuffer = try previousBuffer.map {
        try processorSourceBuffer(
          from: $0,
          stage: .previousProcessor,
          slot: .previous,
          session: session,
          instruction: instruction
        )
      }
      let processorNextBuffer = try nextBuffer.map {
        try processorSourceBuffer(
          from: $0,
          stage: .nextProcessor,
          slot: .next,
          session: session,
          instruction: instruction
        )
      }
      let destinationBuffer = try session.destinationPixelBuffer()
      try validateGeometry(
        of: destinationBuffer,
        expected: instruction.geometry.processorInputSize,
        stage: .processorDestination
      )
      // VideoToolbox writes into a caller-owned buffer and does not promise to
      // copy color metadata. Preserve P3/Rec.709 interpretation when Core Image
      // consumes the motion-blurred half-float pixels.
      copyColorAttachments(
        from: processorCurrentBuffer,
        to: destinationBuffer
      )

      guard
        let currentFrame = VTFrameProcessorFrame(
          buffer: processorCurrentBuffer,
          presentationTimeStamp: request.compositionTime
        ),
        let destinationFrame = VTFrameProcessorFrame(
          buffer: destinationBuffer,
          presentationTimeStamp: request.compositionTime
        )
      else {
        throw MotionBlurError.cannotWrapPixelBuffer
      }

      let previousFrame: VTFrameProcessorFrame?
      if let processorPreviousBuffer {
        guard
          let frame = VTFrameProcessorFrame(
            buffer: processorPreviousBuffer,
            presentationTimeStamp: request.compositionTime - instruction.frameDuration
          )
        else {
          throw MotionBlurError.cannotWrapPixelBuffer
        }
        previousFrame = frame
      } else {
        previousFrame = nil
      }
      let nextFrame: VTFrameProcessorFrame?
      if let processorNextBuffer {
        guard
          let frame = VTFrameProcessorFrame(
            buffer: processorNextBuffer,
            presentationTimeStamp: request.compositionTime + instruction.frameDuration
          )
        else {
          throw MotionBlurError.cannotWrapPixelBuffer
        }
        nextFrame = frame
      } else {
        nextFrame = nil
      }
      let submissionMode = resolveSubmissionMode(
        compositionTime: request.compositionTime,
        expectedFrameDuration: instruction.frameDuration,
        generation: cancellationTicket.generation
      )
      guard
        let parameters = VTMotionBlurParameters(
          sourceFrame: currentFrame,
          nextFrame: nextFrame,
          previousFrame: previousFrame,
          nextOpticalFlow: nil,
          previousOpticalFlow: nil,
          motionBlurStrength: strengthSource.snapshot(),
          submissionMode: submissionMode,
          destinationFrame: destinationFrame
        )
      else {
        throw MotionBlurError.cannotCreateParameters
      }

      try session.process(parameters: parameters)
      guard requestCoordinator.isCurrent(cancellationTicket) else {
        throw CancellationError()
      }
      lastCompositionTime = request.compositionTime
      lastSubmissionGeneration = cancellationTicket.generation

      return try compose(
        imageBuffer: destinationBuffer,
        currentBuffer: currentBuffer,
        imageTransform: instruction.geometry.processorToRenderTransform,
        instruction: instruction,
        request: request
      )
    #endif
  }

  /// Resolves one requested source frame using Preview's drop policy.
  ///
  /// AVFoundation can briefly omit a source while the same player item adopts
  /// a new video composition. Realtime Preview cancels that obsolete request
  /// and lets the player ask again; offline Export still treats it as a hard
  /// source-contract failure.
  private func sourceFrame(
    byTrackID trackID: CMPersistentTrackID,
    stage: MotionBlurFrameStage,
    instruction: MotionBlurCompositionInstruction,
    request: AVAsynchronousVideoCompositionRequest
  ) throws -> CVPixelBuffer {
    if let sourceFrame = request.sourceFrame(byTrackID: trackID) {
      return sourceFrame
    }
    if instruction.allowsRealtimeFrameDropping {
      throw CancellationError()
    }
    throw MotionBlurError.missingSourceFrame(stage)
  }

  private func compose(
    imageBuffer: CVPixelBuffer,
    currentBuffer: CVPixelBuffer,
    imageTransform: CGAffineTransform,
    instruction: MotionBlurCompositionInstruction,
    request: AVAsynchronousVideoCompositionRequest
  ) throws -> CVPixelBuffer {
    let outputBuffer = try request.renderContext.makePixelBuffer()
    try validateGeometry(
      of: outputBuffer,
      expected: instruction.geometry.compositionRenderSize,
      stage: .renderContext
    )
    let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
    let motionBlurredImage =
      sourceImage
      .transformed(by: imageTransform)
    let outputImage = try instruction.postProcessor(
      motionBlurredImage,
      instruction.renderExtent
    )
    let renderColorSpace =
      instruction.outputColorSpace
      ?? CVImageBufferGetColorSpace(outputBuffer)?.takeUnretainedValue()
      ?? sourceImage.colorSpace
      ?? CIImage(cvPixelBuffer: currentBuffer).colorSpace
      ?? CGColorSpace(name: CGColorSpace.itur_709)
    // Keep render-context geometry attachments intact; the composition's
    // color properties tag the final pixel buffer and encoded movie.
    instruction.ciContext.render(
      outputImage,
      to: outputBuffer,
      bounds: instruction.renderExtent,
      colorSpace: renderColorSpace
    )
    return outputBuffer
  }

  #if !targetEnvironment(simulator)
    /// Converts a decoded frame into the one canonical pixel space consumed by
    /// every temporal input of the VideoToolbox session.
    ///
    /// Preview downsampling and physical-portrait canonicalization happen in
    /// three session-owned IOSurface slots. Requests are serialized, so each
    /// slot is reused only after VideoToolbox has completed the prior request.
    private func processorSourceBuffer(
      from sourceBuffer: CVPixelBuffer,
      stage: MotionBlurFrameStage,
      slot: MotionBlurProcessorSourceBufferSlot,
      session: MotionBlurProcessorSession,
      instruction: MotionBlurCompositionInstruction
    ) throws -> CVPixelBuffer {
      if instruction.geometry.usesSourceBuffersDirectly,
        CVPixelBufferGetPixelFormatType(sourceBuffer)
          == session.sourcePixelFormat
      {
        try validateGeometry(
          of: sourceBuffer,
          expected: instruction.geometry.processorInputSize,
          stage: stage
        )
        return sourceBuffer
      }

      let processorBuffer = try session.sourcePixelBuffer(for: slot)
      copyColorAttachments(from: sourceBuffer, to: processorBuffer)

      let processorExtent = CGRect(
        origin: .zero,
        size: instruction.geometry.processorInputSize
      )
      let sourceImage = CIImage(cvPixelBuffer: sourceBuffer)
      let processorImage =
        sourceImage
        .transformed(by: instruction.geometry.sourceToProcessorTransform)
        .cropped(to: processorExtent)
      let colorSpace =
        CVImageBufferGetColorSpace(processorBuffer)?.takeUnretainedValue()
        ?? sourceImage.colorSpace
        ?? CGColorSpace(name: CGColorSpace.itur_709)
      instruction.ciContext.render(
        processorImage,
        to: processorBuffer,
        bounds: processorExtent,
        colorSpace: colorSpace
      )
      try validateGeometry(
        of: processorBuffer,
        expected: instruction.geometry.processorInputSize,
        stage: stage
      )
      return processorBuffer
    }

    private func processorSession(
      width: Int,
      height: Int,
      sourcePixelFormat: OSType,
      quality: MotionBlurQuality
    ) throws -> MotionBlurProcessorSession {
      if let processorSession,
        processorSession.width == width,
        processorSession.height == height,
        processorSession.sourcePixelFormat == sourcePixelFormat,
        processorSession.quality == quality
      {
        return processorSession
      }

      // Clear ownership before construction so a failed replacement cannot
      // leave an ended session reachable for the next frame.
      resetProcessorSession()
      let newSession = try MotionBlurProcessorSession(
        width: width,
        height: height,
        sourcePixelFormat: sourcePixelFormat,
        quality: quality
      )
      processorSession = newSession
      return newSession
    }

    private func resolveSubmissionMode(
      compositionTime: CMTime,
      expectedFrameDuration: CMTime,
      generation: UInt
    ) -> VTMotionBlurParameters.SubmissionMode {
      guard
        lastSubmissionGeneration == generation,
        let lastCompositionTime,
        compositionTime > lastCompositionTime
      else {
        return .random
      }

      let expectedNextTime = lastCompositionTime + expectedFrameDuration
      return CMTimeCompare(compositionTime, expectedNextTime) == 0
        ? .sequential
        : .random
    }

    private func scheduleProcessorSessionReset() {
      renderingQueue.async { [weak self] in
        self?.resetProcessorSession()
      }
    }

    /// Connects app-owned OFF transitions to this compositor's private session.
    private func registerProcessorSessionReset(
      with source: MotionBlurStrengthSource
    ) {
      let identifier = ObjectIdentifier(source)
      guard registeredStrengthSources[identifier] == nil else { return }
      registeredStrengthSources[identifier] = source
      source.registerProcessorSessionResetHandler(
        id: processorSessionResetRegistrationID
      ) { [weak self] in
        self?.scheduleProcessorSessionReset()
      }
    }

    private func resetProcessorSession() {
      processorSession?.end()
      processorSession = nil
      lastCompositionTime = nil
      lastSubmissionGeneration = nil
    }
  #else
    private func scheduleProcessorSessionReset() {}
  #endif
}

/// Enforces AVFoundation, Core Image, and VideoToolbox's shared frame-size
/// contract at the exact boundary where a mismatched buffer would otherwise
/// fail later with an opaque framework error.
private func validateGeometry(
  of pixelBuffer: CVPixelBuffer,
  expected: CGSize,
  stage: MotionBlurFrameStage
) throws {
  let actual = CGSize(
    width: CVPixelBufferGetWidth(pixelBuffer),
    height: CVPixelBufferGetHeight(pixelBuffer)
  )
  guard actual == expected else {
    throw MotionBlurError.inconsistentFrameGeometry(
      stage: stage,
      expected: expected,
      actual: actual
    )
  }
}

/// Copies only metadata that affects RGB interpretation.
///
/// Full attachment propagation would also copy clean aperture and pixel aspect
/// ratio from the unrotated source into a differently sized render-context
/// buffer.
private func copyColorAttachments(
  from source: CVPixelBuffer,
  to destination: CVPixelBuffer
) {
  copyAttachment(kCVImageBufferCGColorSpaceKey, from: source, to: destination)
  copyAttachment(kCVImageBufferICCProfileKey, from: source, to: destination)
  copyAttachment(kCVImageBufferColorPrimariesKey, from: source, to: destination)
  copyAttachment(kCVImageBufferTransferFunctionKey, from: source, to: destination)
  copyAttachment(kCVImageBufferYCbCrMatrixKey, from: source, to: destination)
  copyAttachment(kCVImageBufferGammaLevelKey, from: source, to: destination)
  copyAttachment(kCVImageBufferLogTransferFunctionKey, from: source, to: destination)
}

private func copyAttachment(
  _ key: CFString,
  from source: CVPixelBuffer,
  to destination: CVPixelBuffer
) {
  var sourceMode = CVAttachmentMode.shouldPropagate
  guard
    let value = CVBufferCopyAttachment(
      source,
      key,
      &sourceMode
    )
  else {
    // Reusable working buffers may still carry this key from the prior frame.
    CVBufferRemoveAttachment(destination, key)
    return
  }
  CVBufferSetAttachment(
    destination,
    key,
    value,
    .shouldPropagate
  )
}

extension AVVideoCompositionRenderContext {
  fileprivate func makePixelBuffer() throws -> CVPixelBuffer {
    guard let pixelBuffer = newPixelBuffer() else {
      throw MotionBlurError.cannotCreateRenderContextPixelBuffer
    }
    return pixelBuffer
  }
}

/// Registers every AVFoundation request atomically with its cancellation
/// generation and delivers exactly one terminal callback.
///
/// Queued work is cancelled immediately by `cancelCurrentGenerationAndWait`.
/// In-flight VideoToolbox work cannot be interrupted, so cancellation waits for
/// that callback and then reports the request as cancelled.
private final class MotionBlurRequestCoordinator: @unchecked Sendable {

  enum Mode: Equatable, Sendable {
    /// Interactive playback may discard an obsolete queued frame to stay live.
    case realtime
    /// Offline rendering must complete every requested frame.
    case offline
  }

  struct Ticket: Hashable, Sendable {
    fileprivate let id: UInt64
    fileprivate let generation: UInt
  }

  struct Registration {
    let ticket: Ticket
    let supersededDeliveries: [SupersededDelivery]
  }

  struct SupersededDelivery {
    let ticket: Ticket
    let request: AVAsynchronousVideoCompositionRequest
  }

  enum Result {
    case frame(CVPixelBuffer)
    case cancelled
    case failed(any Error)
  }

  private enum State: Equatable {
    case queued
    case rendering
    case finishing(deliveryThread: ObjectIdentifier)
  }

  private struct Entry {
    let request: AVAsynchronousVideoCompositionRequest
    let generation: UInt
    let mode: Mode
    var state: State
  }

  private let condition = NSCondition()
  private var generation: UInt = 0
  private var nextID: UInt64 = 0
  private var entries: [UInt64: Entry] = [:]

  func register(
    _ request: AVAsynchronousVideoCompositionRequest,
    mode: Mode
  ) -> Registration {
    condition.withLock {
      let supersededDeliveries: [SupersededDelivery]
      if mode == .realtime {
        let deliveryThread = ObjectIdentifier(Thread.current)
        let supersededIDs = entries.compactMap { id, entry in
          entry.mode == .realtime && entry.state == .queued
            ? id
            : nil
        }
        supersededDeliveries = supersededIDs.compactMap { id in
          guard var entry = entries[id] else { return nil }
          entry.state = .finishing(deliveryThread: deliveryThread)
          entries[id] = entry
          return SupersededDelivery(
            ticket: Ticket(id: id, generation: entry.generation),
            request: entry.request
          )
        }
      } else {
        supersededDeliveries = []
      }

      let ticket = Ticket(id: nextID, generation: generation)
      nextID &+= 1
      entries[ticket.id] = Entry(
        request: request,
        generation: generation,
        mode: mode,
        state: .queued
      )
      return Registration(
        ticket: ticket,
        supersededDeliveries: supersededDeliveries
      )
    }
  }

  func completeSupersededDelivery(_ ticket: Ticket) {
    condition.withLock {
      guard
        let entry = entries[ticket.id],
        entry.generation == ticket.generation,
        case .finishing = entry.state
      else {
        return
      }
      entries.removeValue(forKey: ticket.id)
      condition.broadcast()
    }
  }

  func beginRendering(
    _ ticket: Ticket
  ) -> AVAsynchronousVideoCompositionRequest? {
    condition.withLock {
      guard var entry = entries[ticket.id], entry.state == .queued else {
        return nil
      }
      entry.state = .rendering
      entries[ticket.id] = entry
      return entry.request
    }
  }

  func isCurrent(_ ticket: Ticket) -> Bool {
    condition.withLock {
      generation == ticket.generation
    }
  }

  func finish(
    _ ticket: Ticket,
    result: Result
  ) {
    let request = condition.withLock { () -> AVAsynchronousVideoCompositionRequest? in
      guard var entry = entries[ticket.id], entry.state == .rendering else {
        return nil
      }
      // Record the delivery thread so only a cancellation synchronously
      // re-entered by this callback can exclude the finishing entry.
      entry.state = .finishing(
        deliveryThread: ObjectIdentifier(Thread.current)
      )
      entries[ticket.id] = entry
      condition.broadcast()
      return entry.request
    }
    guard let request else { return }

    switch result {
    case .frame(let pixelBuffer):
      request.finish(withComposedVideoFrame: pixelBuffer)
    case .cancelled:
      request.finishCancelledRequest()
    case .failed(let error):
      request.finish(with: error)
    }

    condition.withLock {
      entries.removeValue(forKey: ticket.id)
      condition.broadcast()
    }
  }

  func cancelCurrentGenerationAndWait() {
    let cancelledGeneration: UInt
    let cancellationThread = ObjectIdentifier(Thread.current)

    condition.lock()
    cancelledGeneration = generation
    generation &+= 1
    condition.unlock()

    // Claim one request at a time. If its callback synchronously re-enters
    // cancellation, the nested call can drain the still-queued remainder
    // without either call delivering a request twice.
    while let (id, request) = claimOneQueuedRequest(
      upTo: cancelledGeneration,
      deliveryThread: cancellationThread
    ) {
      request.finishCancelledRequest()
      condition.withLock {
        entries.removeValue(forKey: id)
        condition.broadcast()
      }
    }

    condition.lock()
    while entries.values.contains(where: { entry in
      guard entry.generation <= cancelledGeneration else { return false }
      switch entry.state {
      case .queued:
        return false
      case .rendering:
        return true
      case .finishing(let deliveryThread):
        // Waiting for a terminal callback that synchronously re-entered this
        // method on the same thread would deadlock. Other callers still wait
        // until that callback returns and removes the entry.
        return deliveryThread != cancellationThread
      }
    }) {
      condition.wait()
    }
    condition.unlock()
  }

  private func claimOneQueuedRequest(
    upTo cancelledGeneration: UInt,
    deliveryThread: ObjectIdentifier
  ) -> (id: UInt64, request: AVAsynchronousVideoCompositionRequest)? {
    condition.withLock {
      guard
        let id = entries.keys.sorted().first(where: { id in
          guard let entry = entries[id] else { return false }
          return
            entry.generation <= cancelledGeneration
            && entry.state == .queued
        }),
        var entry = entries[id]
      else {
        return nil
      }
      entry.state = .finishing(deliveryThread: deliveryThread)
      entries[id] = entry
      return (id, entry.request)
    }
  }
}

extension NSCondition {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

#if !targetEnvironment(simulator)
  /// The temporal role of one reusable processor input buffer.
  ///
  /// A request may need all three roles at once, so roles never share a buffer.
  /// The compositor's serial queue permits each role to reuse its buffer after
  /// the prior VideoToolbox callback has completed.
  private enum MotionBlurProcessorSourceBufferSlot: Int, Hashable {
    case current
    case previous
    case next
  }

  /// One configured VideoToolbox session and its bounded working-buffer set.
  private final class MotionBlurProcessorSession {
    let width: Int
    let height: Int
    let sourcePixelFormat: OSType
    let quality: MotionBlurQuality

    private let processor: VTFrameProcessor
    private let sourcePool: CVPixelBufferPool
    private let destinationPool: CVPixelBufferPool
    private var sourceBuffers: [MotionBlurProcessorSourceBufferSlot: CVPixelBuffer] = [:]
    private var destinationBuffer: CVPixelBuffer?

    init(
      width: Int,
      height: Int,
      sourcePixelFormat: OSType,
      quality: MotionBlurQuality
    ) throws {
      guard
        let configuration = VTMotionBlurConfiguration(
          frameWidth: width,
          frameHeight: height,
          usePrecomputedFlow: false,
          qualityPrioritization: quality.videoToolboxValue,
          revision: VTMotionBlurConfiguration.defaultRevision
        )
      else {
        throw MotionBlurError.cannotCreateFrameProcessor
      }
      guard
        configuration.supportedPixelFormats.contains(sourcePixelFormat)
      else {
        throw MotionBlurError.cannotCreateFrameProcessor
      }

      let processor = VTFrameProcessor()
      try processor.startSession(configuration: configuration)

      let requestedAttributes: [String: any Sendable] = [
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferPixelFormatTypeKey as String: Int(sourcePixelFormat),
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String],
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]

      let sourcePool: CVPixelBufferPool
      let destinationPool: CVPixelBufferPool
      do {
        sourcePool = try Self.makePixelBufferPool(
          configurationAttributes:
            configuration.sourcePixelBufferAttributes as CFDictionary,
          requestedAttributes: requestedAttributes,
          minimumBufferCount: 3
        )
        destinationPool = try Self.makePixelBufferPool(
          configurationAttributes:
            configuration.destinationPixelBufferAttributes as CFDictionary,
          requestedAttributes: requestedAttributes,
          minimumBufferCount: 1
        )
      } catch {
        processor.endSession()
        throw error
      }

      self.width = width
      self.height = height
      self.sourcePixelFormat = sourcePixelFormat
      self.quality = quality
      self.processor = processor
      self.sourcePool = sourcePool
      self.destinationPool = destinationPool
    }

    /// Returns the stable working buffer assigned to one temporal input role.
    ///
    /// Buffers are allocated lazily because source-sized landscape frames can
    /// bypass this pool, while Preview downsampling and portrait
    /// canonicalization need up to exactly three roles.
    func sourcePixelBuffer(
      for slot: MotionBlurProcessorSourceBufferSlot
    ) throws -> CVPixelBuffer {
      if let sourceBuffer = sourceBuffers[slot] {
        return sourceBuffer
      }
      let sourceBuffer = try Self.makePixelBuffer(from: sourcePool)
      sourceBuffers[slot] = sourceBuffer
      return sourceBuffer
    }

    /// Returns the single output buffer reused by serialized process calls.
    func destinationPixelBuffer() throws -> CVPixelBuffer {
      if let destinationBuffer {
        return destinationBuffer
      }
      let destinationBuffer = try Self.makePixelBuffer(from: destinationPool)
      self.destinationBuffer = destinationBuffer
      return destinationBuffer
    }

    private static func makePixelBuffer(
      from pool: CVPixelBufferPool
    ) throws -> CVPixelBuffer {
      var pixelBuffer: CVPixelBuffer?
      let status = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault,
        pool,
        &pixelBuffer
      )
      guard status == kCVReturnSuccess, let pixelBuffer else {
        throw MotionBlurError.cannotCreateProcessorPixelBuffer
      }
      return pixelBuffer
    }

    private static func makePixelBufferPool(
      configurationAttributes: CFDictionary,
      requestedAttributes: [String: any Sendable],
      minimumBufferCount: Int
    ) throws -> CVPixelBufferPool {
      let attributeSets =
        [
          configurationAttributes,
          requestedAttributes as CFDictionary,
        ] as CFArray
      var resolvedAttributes: CFDictionary?
      let resolveStatus = CVPixelBufferCreateResolvedAttributesDictionary(
        kCFAllocatorDefault,
        attributeSets,
        &resolvedAttributes
      )
      guard resolveStatus == kCVReturnSuccess, let resolvedAttributes else {
        throw MotionBlurError.cannotCreateProcessorPixelBufferPool
      }

      var pool: CVPixelBufferPool?
      let poolStatus = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        [
          kCVPixelBufferPoolMinimumBufferCountKey as String:
            minimumBufferCount
        ] as CFDictionary,
        resolvedAttributes,
        &pool
      )
      guard poolStatus == kCVReturnSuccess, let pool else {
        throw MotionBlurError.cannotCreateProcessorPixelBufferPool
      }
      return pool
    }

    func process(parameters: VTMotionBlurParameters) throws {
      let completion = MotionBlurProcessCompletion()
      processor.process(parameters: parameters) { _, error in
        completion.finish(with: error)
      }
      try completion.wait()
    }

    func end() {
      processor.endSession()
      sourceBuffers.removeAll(keepingCapacity: false)
      destinationBuffer = nil
      CVPixelBufferPoolFlush(sourcePool, .excessBuffers)
      CVPixelBufferPoolFlush(destinationPool, .excessBuffers)
    }
  }

  extension MotionBlurQuality {
    fileprivate var videoToolboxValue: VTMotionBlurConfiguration.QualityPrioritization {
      switch self {
      case .normal:
        return .normal
      case .quality:
        return .quality
      }
    }
  }

  /// Bridges VideoToolbox's callback API while keeping requests serialized.
  private final class MotionBlurProcessCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var error: (any Error)?

    func finish(with error: (any Error)?) {
      lock.withLock {
        self.error = error
      }
      semaphore.signal()
    }

    func wait() throws {
      semaphore.wait()
      if let error = lock.withLock({ error }) {
        throw error
      }
    }
  }
#endif
