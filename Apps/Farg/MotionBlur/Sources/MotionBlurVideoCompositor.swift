//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import VideoToolbox

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
  let settings: MotionBlurSettings
  let quality: MotionBlurQuality
  let allowsRealtimeFrameDropping: Bool
  let frameDuration: CMTime
  let sourceTransform: CGAffineTransform
  let renderExtent: CGRect
  let ciContext: CIContext
  let postProcessor: PostProcessor

  init(
    timeRange: CMTimeRange,
    previousTrackID: CMPersistentTrackID?,
    currentTrackID: CMPersistentTrackID,
    nextTrackID: CMPersistentTrackID?,
    settings: MotionBlurSettings,
    quality: MotionBlurQuality,
    allowsRealtimeFrameDropping: Bool,
    frameDuration: CMTime,
    sourceTransform: CGAffineTransform,
    renderExtent: CGRect,
    ciContext: CIContext,
    postProcessor: @escaping PostProcessor
  ) {
    self.timeRange = timeRange
    self.previousTrackID = previousTrackID
    self.currentTrackID = currentTrackID
    self.nextTrackID = nextTrackID
    self.settings = settings
    self.quality = quality
    self.allowsRealtimeFrameDropping = allowsRealtimeFrameDropping
    self.frameDuration = frameDuration
    self.sourceTransform = sourceTransform
    self.renderExtent = renderExtent
    self.ciContext = ciContext
    self.postProcessor = postProcessor
    self.requiredSourceTrackIDs = [
      previousTrackID,
      currentTrackID,
      nextTrackID,
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
      Int(kCVPixelFormatType_64RGBAHalf),
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String],
    kCVPixelBufferMetalCompatibilityKey as String: true,
  ]

  public let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String],
    kCVPixelBufferMetalCompatibilityKey as String: true,
  ]

  /// Preserve wide-gamut SDR inputs; AVFoundation still converts HDR inputs to
  /// the composition's SDR color space before the VideoToolbox processor.
  public let supportsWideColorSourceFrames = true
  public let supportsHDRSourceFrames = false
  public let canConformColorOfSourceFrames = false

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
  #endif

  public override init() {
    super.init()
  }

  deinit {
    #if !targetEnvironment(simulator)
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
        request.videoCompositionInstruction as? MotionBlurCompositionInstruction,
      let currentBuffer = request.sourceFrame(
        byTrackID: instruction.currentTrackID
      )
    else {
      throw MotionBlurError.cannotWrapPixelBuffer
    }

    #if targetEnvironment(simulator)
      throw MotionBlurError.unavailable
    #else
      let previousBuffer: CVPixelBuffer?
      if let previousTrackID = instruction.previousTrackID {
        guard let buffer = request.sourceFrame(byTrackID: previousTrackID) else {
          throw MotionBlurError.cannotWrapPixelBuffer
        }
        previousBuffer = buffer
      } else {
        previousBuffer = nil
      }
      let nextBuffer: CVPixelBuffer?
      if let nextTrackID = instruction.nextTrackID {
        guard let buffer = request.sourceFrame(byTrackID: nextTrackID) else {
          throw MotionBlurError.cannotWrapPixelBuffer
        }
        nextBuffer = buffer
      } else {
        nextBuffer = nil
      }
      let sourcePixelFormat = CVPixelBufferGetPixelFormatType(currentBuffer)
      let sourceBuffers = [previousBuffer, currentBuffer, nextBuffer].compactMap { $0 }
      guard
        sourcePixelFormat == kCVPixelFormatType_64RGBAHalf,
        sourceBuffers.allSatisfy({
          CVPixelBufferGetPixelFormatType($0) == sourcePixelFormat
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
          instruction: instruction,
          request: request
        )
      }

      let session = try processorSession(
        width: CVPixelBufferGetWidth(currentBuffer),
        height: CVPixelBufferGetHeight(currentBuffer),
        sourcePixelFormat: sourcePixelFormat,
        quality: instruction.quality
      )
      let destinationBuffer = try session.makeDestinationPixelBuffer()
      // VideoToolbox writes into a caller-owned buffer and does not promise to
      // copy color metadata. Preserve P3/Rec.709 interpretation when Core Image
      // consumes the motion-blurred half-float pixels.
      copyColorAttachments(
        from: currentBuffer,
        to: destinationBuffer
      )

      guard
        let currentFrame = VTFrameProcessorFrame(
          buffer: currentBuffer,
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
      if let previousBuffer {
        guard
          let frame = VTFrameProcessorFrame(
            buffer: previousBuffer,
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
      if let nextBuffer {
        guard
          let frame = VTFrameProcessorFrame(
            buffer: nextBuffer,
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
          motionBlurStrength: instruction.settings.strength,
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
        instruction: instruction,
        request: request
      )
    #endif
  }

  private func compose(
    imageBuffer: CVPixelBuffer,
    currentBuffer: CVPixelBuffer,
    instruction: MotionBlurCompositionInstruction,
    request: AVAsynchronousVideoCompositionRequest
  ) throws -> CVPixelBuffer {
    let outputBuffer = try request.renderContext.makePixelBuffer()
    let sourceImage = CIImage(cvPixelBuffer: imageBuffer)
    let motionBlurredImage =
      sourceImage
      .transformed(by: instruction.sourceTransform)
    let outputImage = try instruction.postProcessor(
      motionBlurredImage,
      instruction.renderExtent
    )
    let renderColorSpace =
      CVImageBufferGetColorSpace(outputBuffer)?.takeUnretainedValue()
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
      throw MotionBlurError.cannotCreatePixelBuffer
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
  /// One configured VideoToolbox session and its compatible destination pool.
  private final class MotionBlurProcessorSession {
    let width: Int
    let height: Int
    let sourcePixelFormat: OSType
    let quality: MotionBlurQuality

    private let processor: VTFrameProcessor
    private let destinationPool: CVPixelBufferPool

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
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String],
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ]
      let attributeSets =
        [
          configuration.destinationPixelBufferAttributes as CFDictionary,
          requestedAttributes as CFDictionary,
        ] as CFArray
      var resolvedAttributes: CFDictionary?
      let resolveStatus = CVPixelBufferCreateResolvedAttributesDictionary(
        kCFAllocatorDefault,
        attributeSets,
        &resolvedAttributes
      )
      guard resolveStatus == kCVReturnSuccess, let resolvedAttributes else {
        processor.endSession()
        throw MotionBlurError.cannotCreatePixelBuffer
      }

      var pool: CVPixelBufferPool?
      let poolStatus = CVPixelBufferPoolCreate(
        kCFAllocatorDefault,
        nil,
        resolvedAttributes,
        &pool
      )
      guard poolStatus == kCVReturnSuccess, let pool else {
        processor.endSession()
        throw MotionBlurError.cannotCreatePixelBuffer
      }

      self.width = width
      self.height = height
      self.sourcePixelFormat = sourcePixelFormat
      self.quality = quality
      self.processor = processor
      self.destinationPool = pool
    }

    func makeDestinationPixelBuffer() throws -> CVPixelBuffer {
      var pixelBuffer: CVPixelBuffer?
      let status = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault,
        destinationPool,
        &pixelBuffer
      )
      guard status == kCVReturnSuccess, let pixelBuffer else {
        throw MotionBlurError.cannotCreatePixelBuffer
      }
      return pixelBuffer
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
