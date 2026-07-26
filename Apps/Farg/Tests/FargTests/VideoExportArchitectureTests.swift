import AVFoundation
import BackgroundTasks
import BrightroomParametric
import Dispatch
import FargMotionBlur
import Foundation
import Testing

@testable import Farg

@Suite("Background export resource policy")
struct VideoExportBackgroundResourceDecisionTests {

  @Test
  func motionBlurRequiresForegroundWithoutBackgroundGPU() {
    let decision = VideoExportBackgroundResourceDecision.resolve(
      isMotionBlurEnabled: true,
      supportedResources: []
    )

    #expect(decision == .foreground(.motionBlurRequiresForeground))
  }

  @Test
  func motionBlurRequestsAnAvailableBackgroundGPU() {
    let decision = VideoExportBackgroundResourceDecision.resolve(
      isMotionBlurEnabled: true,
      supportedResources: [.gpu]
    )

    #expect(decision == .submitRequiringGPU)
  }

  @Test
  func ordinaryExportRetainsDefaultBackgroundResources() {
    let decision = VideoExportBackgroundResourceDecision.resolve(
      isMotionBlurEnabled: false,
      supportedResources: []
    )

    #expect(decision == .submitWithDefaultResources)
  }

  @Test
  func ordinaryExportRetainsTheExistingGPURequestWhenAvailable() {
    let decision = VideoExportBackgroundResourceDecision.resolve(
      isMotionBlurEnabled: false,
      supportedResources: [.gpu]
    )

    #expect(decision == .submitRequiringGPU)
  }
}

@Suite("Video render resource gate")
struct VideoRenderResourceGateTests {

  @Test
  func capacityOneSerializesOperations() async throws {
    let gate = VideoRenderResourceGate(capacity: 1)
    let operation = ControlledOperation()

    let first = Task {
      try await gate.withPermit {
        await operation.run(id: 1)
      }
    }
    await operation.waitUntilStarted(count: 1)

    let second = Task {
      try await gate.withPermit {
        await operation.run(id: 2)
      }
    }
    await waitForQueuedCount(1, in: gate)

    var snapshot = await operation.snapshot()
    #expect(snapshot.started == [1])
    #expect(snapshot.maximumActiveCount == 1)

    await operation.release(id: 1)
    await operation.waitUntilStarted(count: 2)
    await operation.release(id: 2)
    try await first.value
    try await second.value

    snapshot = await operation.snapshot()
    #expect(snapshot.started == [1, 2])
    #expect(snapshot.maximumActiveCount == 1)
  }

  @Test
  func capacityTwoAllowsTwoOperations() async throws {
    let gate = VideoRenderResourceGate(capacity: 2)
    let operation = ControlledOperation()

    let first = Task {
      try await gate.withPermit {
        await operation.run(id: 1)
      }
    }
    await operation.waitUntilStarted(count: 1)

    let second = Task {
      try await gate.withPermit {
        await operation.run(id: 2)
      }
    }
    await operation.waitUntilStarted(count: 2)

    let third = Task {
      try await gate.withPermit {
        await operation.run(id: 3)
      }
    }
    await waitForQueuedCount(1, in: gate)

    var snapshot = await operation.snapshot()
    #expect(snapshot.started == [1, 2])
    #expect(snapshot.maximumActiveCount == 2)

    await operation.release(id: 1)
    await operation.waitUntilStarted(count: 3)
    await operation.release(id: 2)
    await operation.release(id: 3)
    try await first.value
    try await second.value
    try await third.value

    snapshot = await operation.snapshot()
    #expect(snapshot.started == [1, 2, 3])
    #expect(snapshot.maximumActiveCount == 2)
  }

  @Test
  func cancellingAQueuedOperationDoesNotLeakCapacity() async throws {
    let gate = VideoRenderResourceGate(capacity: 1)
    let operation = ControlledOperation()

    let first = Task {
      try await gate.withPermit {
        await operation.run(id: 1)
      }
    }
    await operation.waitUntilStarted(count: 1)

    let cancelled = Task {
      try await gate.withPermit {
        await operation.run(id: 2)
      }
    }
    await waitForQueuedCount(1, in: gate)
    cancelled.cancel()

    do {
      try await cancelled.value
      Issue.record("A cancelled gate waiter unexpectedly ran.")
    } catch is CancellationError {
      // Expected.
    }

    await operation.release(id: 1)
    try await first.value

    let third = Task {
      try await gate.withPermit {
        await operation.run(id: 3)
      }
    }
    await operation.waitUntilStarted(count: 2)
    await operation.release(id: 3)
    try await third.value

    let snapshot = await operation.snapshot()
    #expect(snapshot.started == [1, 3])
    #expect(snapshot.maximumActiveCount == 1)
  }

  private func waitForQueuedCount(
    _ expectedCount: Int,
    in gate: VideoRenderResourceGate
  ) async {
    while await gate.queuedCount < expectedCount {
      await Task.yield()
    }
  }
}

@Suite("Asset writer backpressure")
struct AssetWriterBackpressureTests {

  @Test
  func cancellationStopsBeforeAnotherAppendAttempt() async {
    let retryWait = ControlledRetryWait()
    let appender = AssetWriterBackpressureAppender(
      waitForRetry: {
        try await retryWait.suspendOnce()
      }
    )
    let work = Task.detached {
      try await appender.append {
        false
      }
    }

    await retryWait.waitUntilSuspended()
    work.cancel()
    await retryWait.release()

    do {
      try await work.value
      Issue.record("Cancelled writer backpressure unexpectedly resumed.")
    } catch is CancellationError {
      // Expected.
    } catch {
      Issue.record("Writer backpressure ended with \(error).")
    }
  }
}

@Suite("Export attempt cancellation dispatch")
@MainActor
struct ExportAttemptCancellationDispatchTests {

  @Test
  func requestAfterAttachKeepsMainActorResponsive() async {
    await assertResponsive(stickyCancellationBeforeAttach: false)
  }

  @Test
  func stickyCancellationDuringAttachKeepsMainActorResponsive() async {
    await assertResponsive(stickyCancellationBeforeAttach: true)
  }

  private func assertResponsive(
    stickyCancellationBeforeAttach: Bool
  ) async {
    let probe = BlockingCancellationProbe()
    let work = Task.detached(priority: .userInitiated) {
      do {
        try await probe.run()
      } catch {
        // Cancellation is the expected terminal path for this fake worker.
      }
    }
    await probe.waitUntilReady()

    let control = ExportAttemptControl()
    let cancellationWonBeforeAttach: Bool
    if stickyCancellationBeforeAttach {
      cancellationWonBeforeAttach = control.requestCancellation(origin: .user)
    } else {
      control.attach(work)
      cancellationWonBeforeAttach = false
    }

    let cancellation = Task { @MainActor in
      let cancellationWon: Bool
      if stickyCancellationBeforeAttach {
        cancellationWon = cancellationWonBeforeAttach
        control.attach(work)
      } else {
        cancellationWon = control.requestCancellation(origin: .user)
      }
      await control.wait()
      return cancellationWon
    }

    let remainedResponsive =
      await probe.observeMainActorDuringBlockedHandler()
    #expect(await cancellation.value)
    #expect(remainedResponsive)
    #expect(control.cancellationOrigin == .user)
  }
}

@Suite("Video export item identity")
@MainActor
struct VideoExportItemIdentityTests {

  @Test
  func retryKeepsRowIdentityAndRejectsOldAttemptUpdates() {
    let rowID = UUID()
    let item = VideoExportItemModel(
      item: VideoExportSessionItem(
        id: rowID,
        displayName: "Morning",
        source: VideoSource(
          appOwnedURL: URL(filePath: "/tmp/input.mov")
        ),
        colorInfo: .sdrRec709
      ),
      position: 1
    )

    let firstID = UUID()
    let first = item.beginAttempt(
      id: firstID,
      taskIdentifier: "app.muukii.farg.export.\(firstID)",
      outputURL: URL(filePath: "/tmp/first.mov")
    )
    #expect(first?.number == 1)

    item.markWaitingForRenderSlot(
      attemptID: firstID,
      path: .background
    )
    item.markRendering(
      attemptID: firstID,
      path: .background,
      fraction: 0
    )
    item.finish(
      attemptID: firstID,
      with: .failed(path: .background, message: "Failed")
    )

    let secondID = UUID()
    let second = item.beginAttempt(
      id: secondID,
      taskIdentifier: "app.muukii.farg.export.\(secondID)",
      outputURL: URL(filePath: "/tmp/second.mov")
    )

    #expect(item.id == rowID)
    #expect(second?.number == 2)
    #expect(second?.id == secondID)

    item.markRendering(
      attemptID: firstID,
      path: .background,
      fraction: 0.8
    )
    item.finish(
      attemptID: firstID,
      with: .cancelled(path: .background, origin: .system)
    )

    guard let current = item.attempt else {
      Issue.record("The retry attempt disappeared.")
      return
    }
    #expect(current.id == secondID)
    #expect(
      current.state == .active(.preparingBackgroundRequest)
    )
  }

  @Test
  func cancellingAttemptCannotCommitSuccess() {
    let item = VideoExportItemModel(
      item: VideoExportSessionItem(
        id: UUID(),
        displayName: "Evening",
        source: VideoSource(
          appOwnedURL: URL(filePath: "/tmp/input.mov")
        ),
        colorInfo: .sdrRec709
      ),
      position: 1
    )
    let attemptID = UUID()
    _ = item.beginAttempt(
      id: attemptID,
      taskIdentifier: "app.muukii.farg.export.\(attemptID)",
      outputURL: URL(filePath: "/tmp/output.mov")
    )
    item.markWaitingForRenderSlot(
      attemptID: attemptID,
      path: .background
    )
    item.markRendering(
      attemptID: attemptID,
      path: .background,
      fraction: 0
    )
    item.markCancelling(attemptID: attemptID, origin: .user)

    let committedSuccess = item.finish(
      attemptID: attemptID,
      with: .exported(
        path: .background,
        url: URL(filePath: "/tmp/output.mov"),
        photos: .saved
      )
    )
    let committedCancellation = item.finish(
      attemptID: attemptID,
      with: .cancelled(path: .background, origin: .user)
    )

    #expect(committedSuccess == false)
    #expect(committedCancellation)
    #expect(
      item.finish
        == .cancelled(path: .background, origin: .user)
    )
  }
}

@Suite("Video export job runner")
struct VideoExportJobRunnerTests {

  @Test
  func renderAdmissionWaitsForTheRenderPermit() async throws {
    let gate = VideoRenderResourceGate(capacity: 1)
    let blocker = ControlledOperation()
    let admission = AdmissionProbe()
    let holder = Task {
      try await gate.withPermit {
        await blocker.run(id: 1)
      }
    }
    await blocker.waitUntilStarted(count: 1)

    let runner = VideoExportJobRunner(
      exporter: ImmediateExporter(),
      renderGate: gate,
      saveToPhotos: { _ in }
    )
    let queuedRun = Task {
      try await runner.run(
        job: makeJob(outputURL: URL(filePath: "/tmp/admitted.mov")),
        onRenderAdmission: {
          await admission.record()
          return .background
        },
        onPhase: { _, _ in },
        onRenderProgress: { _, _ in }
      )
    }

    while await gate.queuedCount < 1 {
      await Task.yield()
    }
    #expect(await admission.count == 0)

    await blocker.release(id: 1)
    try await holder.value
    let outcome = try await queuedRun.value

    #expect(await admission.count == 1)
    #expect(outcome.path == .background)
  }

  @Test
  func cancellingQueuedRenderDoesNotEnterRenderAdmission() async throws {
    let gate = VideoRenderResourceGate(capacity: 1)
    let blocker = ControlledOperation()
    let admission = AdmissionProbe()
    let holder = Task {
      try await gate.withPermit {
        await blocker.run(id: 1)
      }
    }
    await blocker.waitUntilStarted(count: 1)

    let runner = VideoExportJobRunner(
      exporter: ImmediateExporter(),
      renderGate: gate,
      saveToPhotos: { _ in }
    )
    let queuedRun = Task {
      try await runner.run(
        job: makeJob(outputURL: URL(filePath: "/tmp/cancelled.mov")),
        onRenderAdmission: {
          await admission.record()
          return .background
        },
        onPhase: { _, _ in },
        onRenderProgress: { _, _ in }
      )
    }

    while await gate.queuedCount < 1 {
      await Task.yield()
    }
    queuedRun.cancel()
    do {
      _ = try await queuedRun.value
      Issue.record("A cancelled queued export unexpectedly ran.")
    } catch is CancellationError {
      // Expected.
    }

    #expect(await admission.count == 0)
    await blocker.release(id: 1)
    try await holder.value
  }

  @Test
  func photosFailureKeepsTheRenderedOutputRecoverable() async throws {
    let outputURL = URL(filePath: "/tmp/recoverable.mov")
    let runner = VideoExportJobRunner(
      exporter: ImmediateExporter(),
      renderGate: VideoRenderResourceGate(capacity: 1),
      saveToPhotos: { _ in
        throw PhotoSaveFailure()
      }
    )

    let result = try await runner.run(
      job: makeJob(outputURL: outputURL),
      onRenderAdmission: { .background },
      onPhase: { _, _ in },
      onRenderProgress: { _, _ in }
    )

    #expect(
      result.photos
        == .readyToSave(message: PhotoSaveFailure().localizedDescription)
    )
  }

  @Test
  func cancellationAtTheRenderingPhaseDoesNotStartExport() async throws {
    let renderingPhase = ControlledOperation()
    let exportStart = AdmissionProbe()
    let runner = VideoExportJobRunner(
      exporter: ProbedExporter(probe: exportStart),
      renderGate: VideoRenderResourceGate(capacity: 1),
      saveToPhotos: { _ in }
    )
    let run = Task {
      try await runner.run(
        job: makeJob(
          outputURL: URL(filePath: "/tmp/cancelled-before-export.mov")
        ),
        onRenderAdmission: { .foreground(.motionBlurRequiresForeground) },
        onPhase: { phase, _ in
          if case .rendering = phase {
            await renderingPhase.run(id: 1)
          }
        },
        onRenderProgress: { _, _ in }
      )
    }

    await renderingPhase.waitUntilStarted(count: 1)
    run.cancel()
    await renderingPhase.release(id: 1)

    do {
      _ = try await run.value
      Issue.record("A cancelled attempt unexpectedly started its exporter.")
    } catch is CancellationError {
      // Expected.
    }
    #expect(await exportStart.count == 0)
  }

  @Test
  func cancellationAtThePhotosPhaseDoesNotStartImport() async throws {
    let savingPhase = ControlledOperation()
    let photoSave = AdmissionProbe()
    let runner = VideoExportJobRunner(
      exporter: ImmediateExporter(),
      renderGate: VideoRenderResourceGate(capacity: 1),
      saveToPhotos: { _ in
        await photoSave.record()
      }
    )
    let run = Task {
      try await runner.run(
        job: makeJob(
          outputURL: URL(filePath: "/tmp/cancelled-before-photos.mov")
        ),
        onRenderAdmission: { .foreground(.motionBlurRequiresForeground) },
        onPhase: { phase, _ in
          if case .savingToPhotos = phase {
            await savingPhase.run(id: 1)
          }
        },
        onRenderProgress: { _, _ in }
      )
    }

    await savingPhase.waitUntilStarted(count: 1)
    run.cancel()
    await savingPhase.release(id: 1)

    do {
      _ = try await run.value
      Issue.record("A cancelled export unexpectedly started Photos import.")
    } catch is CancellationError {
      // Expected.
    }
    #expect(await photoSave.count == 0)
  }

  private func makeJob(outputURL: URL) -> VideoExportJob {
    let source = VideoSource(
      appOwnedURL: URL(filePath: "/tmp/input.mov")
    )
    return VideoExportJob(
      sessionID: UUID(),
      itemID: UUID(),
      attemptID: UUID(),
      position: 1,
      displayName: "Morning",
      source: source,
      colorInfo: .sdrRec709,
      recipe: FargVideoRenderRecipe(
        document: EditingDocument(
          mainTree: MainTree(features: [])
        ),
        motionBlur: .disabled
      ),
      outputURL: outputURL,
      taskIdentifier: "app.muukii.farg.export.test"
    )
  }
}

@Suite("Continued-processing progress")
struct ContinuedProcessingProgressTests {

  @Test
  func mapsRealQueueRenderAndPhotosPhasesMonotonically() {
    let relay = ContinuedProcessingTaskRelay(
      displayName: "Morning",
      waitingVideosAhead: 2,
      onExpiration: {}
    )

    var snapshot = relay.currentSnapshot()
    #expect(snapshot.fraction == 0)
    #expect(snapshot.title == "Waiting to export Morning")
    #expect(snapshot.subtitle == "Waiting for 2 earlier videos…")

    relay.updateWaitingProgress(
      predecessorFraction: 0.5,
      videosAhead: 1
    )
    snapshot = relay.currentSnapshot()
    #expect(abs(snapshot.fraction - 0.025) < 0.000_001)
    #expect(snapshot.subtitle == "Waiting for 1 earlier video…")

    relay.beginRendering()
    snapshot = relay.currentSnapshot()
    #expect(abs(snapshot.fraction - 0.05) < 0.000_001)
    #expect(snapshot.title == "Exporting Morning")
    #expect(snapshot.subtitle == "0% complete")

    relay.updateRenderingProgress(0.5)
    snapshot = relay.currentSnapshot()
    #expect(abs(snapshot.fraction - 0.52) < 0.000_001)
    #expect(snapshot.subtitle == "50% complete")

    relay.markSavingToPhotos()
    snapshot = relay.currentSnapshot()
    #expect(snapshot.fraction == 0.99)
    #expect(snapshot.subtitle == "Saving to Photos…")

    relay.markWorkCompleted()
    #expect(relay.currentSnapshot().fraction == 1)
    #expect(relay.complete(success: true))

    relay.updateRenderingProgress(0.1)
    #expect(relay.currentSnapshot().fraction == 1)
  }
}

@Suite("Video render admission dependency")
struct VideoRenderAdmissionDependencyTests {

  @Test
  func capacityOneDependsOnEveryEarlierRender() throws {
    let predecessors = [UUID(), UUID(), UUID()]
    let dependency = VideoRenderAdmissionDependency(
      predecessorAttemptIDs: predecessors,
      renderCapacity: 1
    )

    let snapshot = try #require(
      dependency.snapshot(
        progressByAttemptID: [
          predecessors[0]: 0.2,
          predecessors[1]: 0.4,
          predecessors[2]: 0.6,
        ]
      )
    )

    #expect(dependency.requiredCompletionCount == 3)
    #expect(abs(snapshot.fraction - 0.4) < 0.000_001)
    #expect(snapshot.videosAhead == 3)
  }

  @Test
  func capacityTwoTracksWhicheverRequiredPredecessorsAreMostAdvanced() throws {
    let predecessors = [UUID(), UUID(), UUID()]
    let dependency = VideoRenderAdmissionDependency(
      predecessorAttemptIDs: predecessors,
      renderCapacity: 2
    )

    var snapshot = try #require(
      dependency.snapshot(
        progressByAttemptID: [
          predecessors[0]: 0.1,
          predecessors[1]: 0.8,
          predecessors[2]: 0.6,
        ]
      )
    )
    #expect(dependency.requiredCompletionCount == 2)
    #expect(abs(snapshot.fraction - 0.7) < 0.000_001)
    #expect(snapshot.videosAhead == 2)

    snapshot = try #require(
      dependency.snapshot(
        progressByAttemptID: [
          predecessors[0]: 0.1,
          predecessors[1]: 1,
          predecessors[2]: 0.6,
        ]
      )
    )
    #expect(abs(snapshot.fraction - 0.8) < 0.000_001)
    #expect(snapshot.videosAhead == 1)
  }
}

/// Records when a queued runner reaches its render-admission callback.
private actor AdmissionProbe {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

/// Holds operations until the test explicitly releases each one.
private actor ControlledOperation {

  struct Snapshot: Sendable {
    let started: [Int]
    let maximumActiveCount: Int
  }

  private var activeCount = 0
  private var maximumActiveCount = 0
  private var started: [Int] = []
  private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
  private var startWaiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

  func run(id: Int) async {
    activeCount += 1
    maximumActiveCount = max(maximumActiveCount, activeCount)
    started.append(id)

    if let startWaiter,
      started.count >= startWaiter.count
    {
      self.startWaiter = nil
      startWaiter.continuation.resume()
    }

    await withCheckedContinuation { continuation in
      releases[id] = continuation
    }
    activeCount -= 1
  }

  func waitUntilStarted(count: Int) async {
    guard started.count < count else { return }
    await withCheckedContinuation { continuation in
      precondition(startWaiter == nil)
      startWaiter = (count, continuation)
    }
  }

  func release(id: Int) {
    releases.removeValue(forKey: id)?.resume()
  }

  func snapshot() -> Snapshot {
    Snapshot(
      started: started,
      maximumActiveCount: maximumActiveCount
    )
  }
}

private nonisolated struct ImmediateExporter: VideoExporting {
  func export(
    asset: AVAsset,
    recipe: FargVideoRenderRecipe,
    colorInfo: VideoColorInfo,
    to outputURL: URL,
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws {
    onProgress(1)
  }
}

/// Records exporter entry without performing media work.
private nonisolated struct ProbedExporter: VideoExporting {
  let probe: AdmissionProbe

  func export(
    asset: AVAsset,
    recipe: FargVideoRenderRecipe,
    colorInfo: VideoColorInfo,
    to outputURL: URL,
    onProgress: @escaping @Sendable (Double) -> Void
  ) async throws {
    await probe.record()
  }
}

private nonisolated struct PhotoSaveFailure: LocalizedError {
  var errorDescription: String? {
    "Photos unavailable"
  }
}

/// Suspends the first writer retry until a test explicitly releases it.
private actor ControlledRetryWait {

  private enum UnexpectedRetry: Error {
    case retriedAfterCancellation
  }

  private var waitCount = 0
  private var didSuspend = false
  private var suspensionWaiter: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func suspendOnce() async throws {
    waitCount += 1
    guard waitCount == 1 else {
      throw UnexpectedRetry.retriedAfterCancellation
    }

    didSuspend = true
    suspensionWaiter?.resume()
    suspensionWaiter = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilSuspended() async {
    guard didSuspend == false else { return }
    await withCheckedContinuation { continuation in
      precondition(suspensionWaiter == nil)
      suspensionWaiter = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

/// Holds a synchronous cancellation handler while checking MainActor progress.
private final class BlockingCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var operationContinuation: CheckedContinuation<Void, any Error>?
  private var readinessContinuation: CheckedContinuation<Void, Never>?
  private var isReady = false
  private let entered = DispatchSemaphore(value: 0)
  private let release = DispatchSemaphore(value: 0)
  private let mainActorPing = DispatchSemaphore(value: 0)

  func run() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let readyWaiter = lock.withLock {
          () -> CheckedContinuation<Void, Never>? in
          operationContinuation = continuation
          isReady = true
          defer { readinessContinuation = nil }
          return readinessContinuation
        }
        readyWaiter?.resume()
      }
    } onCancel: {
      entered.signal()
      release.wait()
      finishOnce(throwing: CancellationError())
    }
  }

  func waitUntilReady() async {
    if lock.withLock({ isReady }) {
      return
    }
    await withCheckedContinuation { continuation in
      let shouldResume = lock.withLock {
        if isReady {
          return true
        }
        precondition(readinessContinuation == nil)
        readinessContinuation = continuation
        return false
      }
      if shouldResume {
        continuation.resume()
      }
    }
  }

  func observeMainActorDuringBlockedHandler() async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let didEnter =
          self.entered.wait(
            timeout: DispatchTime.now() + .seconds(5)
          ) == .success
        guard didEnter else {
          self.release.signal()
          self.finishOnce(throwing: CancellationError())
          continuation.resume(returning: false)
          return
        }

        Task { @MainActor in
          self.mainActorPing.signal()
        }
        let didPing =
          self.mainActorPing.wait(
            timeout: DispatchTime.now() + .seconds(5)
          ) == .success
        self.release.signal()
        continuation.resume(returning: didPing)
      }
    }
  }

  private func finishOnce(throwing error: any Error) {
    let continuation = lock.withLock {
      defer { operationContinuation = nil }
      return operationContinuation
    }
    continuation?.resume(throwing: error)
  }
}
