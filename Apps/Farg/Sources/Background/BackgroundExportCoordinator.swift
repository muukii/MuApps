//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BackgroundTasks
import BrightroomParametric
import Foundation
import OSLog

/// Coordinates video export using iOS 26's `BGContinuedProcessingTask` so a
/// render started in the foreground keeps running — with system progress UI —
/// after the user leaves the app, then saves the result to Photos.
///
/// When the continued-processing task can't be scheduled, the coordinator
/// preserves the scheduling error while falling back to a foreground export.
/// `activePath` lets the UI explain both the failure and whether the user may
/// leave the app.
@MainActor
@Observable
final class BackgroundExportCoordinator {

  /// The single permitted task identifier (see `BGTaskSchedulerPermittedIdentifiers`).
  static let taskIdentifier = "app.muukii.farg.export"

  static let shared = BackgroundExportCoordinator()

  private static let logger = Logger(
    subsystem: "app.muukii.farg",
    category: "BackgroundExport"
  )

  enum Phase: Equatable {
    case idle
    case exporting(VideoExportBatchProgress)
    case finished([VideoExportBatchResult])
    case failed(String)
  }

  /// A reason the system couldn't start a background-continuable export.
  enum BackgroundStartError: LocalizedError, Equatable {
    /// `BGTaskScheduler` rejected the continued-processing request.
    case requestSubmissionFailed(
      description: String,
      domain: String,
      code: Int
    )

    var errorDescription: String? {
      switch self {
      case .requestSubmissionFailed(let description, let domain, let code):
        return String(
          localized:
            "The system rejected the background export request: \(description) (\(domain), code \(code)).",
          comment:
            "Background export scheduling error. The variables are the system error description, domain, and numeric code."
        )
      }
    }

    init(submissionError: any Error) {
      let error = submissionError as NSError
      self = .requestSubmissionFailed(
        description: error.localizedDescription,
        domain: error.domain,
        code: error.code
      )
    }
  }

  enum ActivePath: Equatable {
    /// Running as a `BGContinuedProcessingTask` — safe to leave the app.
    case background
    /// Foreground fallback caused by a background scheduling failure.
    case foreground(BackgroundStartError)
  }

  private(set) var phase: Phase = .idle
  private(set) var activePath: ActivePath?

  /// The export strategy. Nonisolated so the background task handler can use it.
  private nonisolated let exporter: any VideoExporting = ParametricVideoExporter()

  /// Holds the job for the system-launched task handler to pick up.
  private nonisolated let jobBox = JobBox()

  /// The in-flight export work, so an explicit cancel can stop it.
  private nonisolated let workHandle = WorkHandle()

  private var didRegister = false
  private var activeJobID: UUID?

  // MARK: - Launch registration

  /// Registers the task handler. Call once, at app launch.
  func registerHandler() {
    guard didRegister == false else { return }
    didRegister = true

    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.taskIdentifier,
      // The handler is formed inside this MainActor-isolated coordinator.
      // Delivering it on the default background queue violates that isolation
      // before the export work can be handed to its nonisolated task.
      using: .main
    ) { [weak self] bgTask in
      guard let task = bgTask as? BGContinuedProcessingTask else {
        bgTask.setTaskCompleted(success: false)
        return
      }
      guard let self, let job = self.jobBox.take() else {
        task.setTaskCompleted(success: false)
        return
      }
      self.run(task: task, job: job)
    }
  }

  // MARK: - Start

  /// Starts a serial batch, preferring the background-continuable task.
  ///
  /// `retainedOutputURLs` keeps successful files from an earlier partial
  /// attempt available while only failed items are retried.
  func start(
    batch: VideoExportBatch,
    retaining retainedOutputURLs: Set<URL> = []
  ) {
    guard case .idle = phase, batch.items.isEmpty == false else { return }

    let job = Job(
      id: batch.id,
      batch: batch,
      outputURLs: batch.items.indices.map { index in
        Self.makeOutputURL(position: index + 1)
      }
    )
    Self.cleanupExportsDirectory(
      keeping: Set(job.outputURLs).union(retainedOutputURLs)
    )
    activeJobID = job.id
    phase = .exporting(
      VideoExportBatchProgress(
        currentItemIndex: 0,
        itemCount: batch.items.count,
        currentItemFraction: 0
      )
    )

    let request = BGContinuedProcessingTaskRequest(
      identifier: Self.taskIdentifier,
      title: Self.exportTitle(itemCount: batch.items.count),
      subtitle: "Rendering your video…"
    )
    request.strategy = .queue
    // Background GPU is an optional resource of a continued-processing task.
    // Submit with default resources when the device doesn't advertise it,
    // matching Apple's documented scheduling pattern.
    if BGTaskScheduler.supportedResources.contains(.gpu) {
      request.requiredResources = .gpu
    } else {
      Self.logger.notice(
        "Background GPU is unavailable; submitting with default resources."
      )
    }

    jobBox.set(job)
    do {
      try BGTaskScheduler.shared.submit(request)
      activePath = .background
      // The system invokes the registered handler, which drives `run(task:job:)`.
    } catch {
      let startError = BackgroundStartError(submissionError: error)
      Self.logger.error("\(startError.localizedDescription, privacy: .public)")
      jobBox.take()
      activePath = .foreground(startError)
      runForeground(job: job)
    }
  }

  /// Clears finished/failed state so a new export can start. No-op cancel if idle.
  func reset() {
    activeJobID = nil
    BGTaskScheduler.shared.cancel(
      taskRequestWithIdentifier: Self.taskIdentifier
    )
    workHandle.cancel()
    jobBox.take()
    phase = .idle
    activePath = nil
  }

  /// Explicitly aborts an in-flight export (background or foreground).
  func cancelAndWait() async {
    activeJobID = nil
    BGTaskScheduler.shared.cancel(
      taskRequestWithIdentifier: Self.taskIdentifier
    )
    jobBox.take()
    if case .exporting = phase {
      phase = .idle
    }
    activePath = nil
    await workHandle.cancelAndWait()
  }

  // MARK: - Background execution (system task handler)

  private nonisolated func run(task: BGContinuedProcessingTask, job: Job) {
    let taskHandle = ContinuedProcessingTaskHandle(task)
    let expirationCancellation = DeferredTaskCancellation()
    taskHandle.setExpirationHandler {
      expirationCancellation.cancel()
    }

    let work = Task { [exporter, taskHandle, expirationCancellation] in
      defer { expirationCancellation.clear() }
      do {
        let results = try await Self.export(
          job: job,
          using: exporter,
          progressUnitCount: ContinuedProcessingTaskHandle.progressUnitCount
        ) { progress in
          // System progress is updated at media-sample granularity so a slow
          // Optical Flow export does not look stalled to the scheduler. The
          // app UI still updates only when the displayed whole percent changes.
          if taskHandle.updateProgress(progress) {
            Task { @MainActor in
              BackgroundExportCoordinator.shared.update(
                progress: progress,
                jobID: job.id
              )
            }
          }
        }
        await MainActor.run {
          BackgroundExportCoordinator.shared.finish(
            .finished(results),
            jobID: job.id
          )
        }
        taskHandle.complete(success: Self.allRendersSucceeded(results))
      } catch is CancellationError {
        Self.removeFiles(job.outputURLs)
        await MainActor.run {
          BackgroundExportCoordinator.shared.markCancelled(jobID: job.id)
        }
        taskHandle.complete(success: false)
      } catch {
        Self.removeFiles(job.outputURLs)
        await MainActor.run {
          BackgroundExportCoordinator.shared.finish(
            .failed(error.localizedDescription),
            jobID: job.id
          )
        }
        taskHandle.complete(success: false)
      }
    }

    expirationCancellation.attach(work)
    workHandle.set(work)
  }

  // MARK: - Foreground fallback

  private func runForeground(job: Job) {
    let work = Task { [exporter] in
      do {
        let results = try await Self.export(
          job: job,
          using: exporter,
          progressUnitCount: 100
        ) { progress in
          Task { @MainActor in
            BackgroundExportCoordinator.shared.update(
              progress: progress,
              jobID: job.id
            )
          }
        }
        finish(.finished(results), jobID: job.id)
      } catch is CancellationError {
        Self.removeFiles(job.outputURLs)
        markCancelled(jobID: job.id)
      } catch {
        Self.removeFiles(job.outputURLs)
        finish(.failed(error.localizedDescription), jobID: job.id)
      }
    }
    workHandle.set(work)
  }

  // MARK: - Phase updates

  /// Monotonic progress that also rejects late updates from a cancelled job.
  fileprivate func update(
    progress: VideoExportBatchProgress,
    jobID: UUID
  ) {
    guard
      activeJobID == jobID,
      case .exporting(let current) = phase,
      progress.overallFraction >= current.overallFraction
    else {
      return
    }
    phase = .exporting(progress)
  }

  fileprivate func finish(_ newPhase: Phase, jobID: UUID) {
    guard activeJobID == jobID else { return }
    phase = newPhase
    activePath = nil
    activeJobID = nil
  }

  fileprivate func markCancelled(jobID: UUID) {
    guard activeJobID == jobID else { return }
    phase = .idle
    activePath = nil
    activeJobID = nil
  }

  // MARK: - Helpers

  /// Renders every item in order. A render failure becomes an item result and
  /// does not prevent later videos from being attempted.
  private nonisolated static func export(
    job: Job,
    using exporter: any VideoExporting,
    progressUnitCount: Int,
    onProgress: @escaping @Sendable (VideoExportBatchProgress) -> Void
  ) async throws -> [VideoExportBatchResult] {
    // Reserve the final one percent of each item for Photos import. The HEVC
    // writer can finish before Photos has committed a large movie, so reporting
    // 100% at that boundary would leave a live background task looking done.
    let itemRenderProgressWeight = 0.99
    let progressEmitter = BatchProgressEmitter(
      itemCount: job.batch.items.count,
      progressUnitCount: progressUnitCount,
      onProgress: onProgress
    )
    var results: [VideoExportBatchResult] = []
    results.reserveCapacity(job.batch.items.count)

    for (index, item) in job.batch.items.enumerated() {
      try Task.checkCancellation()
      let outputURL = job.outputURLs[index]

      do {
        try await exporter.export(
          asset: item.asset,
          recipe: job.batch.recipe,
          colorInfo: item.colorInfo,
          to: outputURL
        ) { fraction in
          progressEmitter.update(
            itemIndex: index,
            itemFraction: fraction * itemRenderProgressWeight
          )
        }
        try Task.checkCancellation()
        let saved = try await saveToPhotos(outputURL)
        try Task.checkCancellation()
        results.append(
          VideoExportBatchResult(
            id: item.id,
            displayName: item.displayName,
            outcome: .exported(
              url: outputURL,
              savedToPhotos: saved
            )
          )
        )
      } catch is CancellationError {
        removeFile(outputURL)
        throw CancellationError()
      } catch {
        removeFile(outputURL)
        results.append(
          VideoExportBatchResult(
            id: item.id,
            displayName: item.displayName,
            outcome: .failed(message: error.localizedDescription)
          )
        )
      }

      progressEmitter.update(itemIndex: index, itemFraction: 1)
    }

    return results
  }

  private nonisolated static func allRendersSucceeded(
    _ results: [VideoExportBatchResult]
  ) -> Bool {
    results.allSatisfy { result in
      switch result.outcome {
      case .exported:
        return true
      case .failed:
        return false
      }
    }
  }

  /// Saves a completed movie while preserving task cancellation as control flow.
  ///
  /// Photos permission and library errors remain a recoverable per-item result,
  /// but expiration or an explicit cancel must terminate the background job.
  private static func saveToPhotos(_ url: URL) async throws -> Bool {
    try Task.checkCancellation()
    do {
      try await PhotoLibrarySaver.save(videoAt: url)
      try Task.checkCancellation()
      return true
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      try Task.checkCancellation()
      return false
    }
  }

  private nonisolated static func cachesExportsDirectory() -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Exports", isDirectory: true)
  }

  private static func exportTitle(itemCount: Int) -> String {
    if itemCount == 1 {
      return String(localized: "Exporting video")
    }
    return String(
      localized: "Exporting \(itemCount) videos",
      comment: "System background-task title. The variable is the number of videos."
    )
  }

  static func makeOutputURL(position: Int) -> URL {
    let directory = cachesExportsDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(
      "Färg-\(position)-\(UUID().uuidString).mov"
    )
  }

  /// Removes previously exported files (already shared/saved) to bound storage.
  private nonisolated static func cleanupExportsDirectory(
    keeping keepURLs: Set<URL>
  ) {
    let directory = cachesExportsDirectory()
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
    else {
      return
    }
    for file in files where keepURLs.contains(file) == false {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private nonisolated static func removeFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  private nonisolated static func removeFiles(_ urls: [URL]) {
    for url in urls {
      removeFile(url)
    }
  }

  struct Job {
    let id: UUID
    let batch: VideoExportBatch
    let outputURLs: [URL]
  }
}

/// A lock-guarded box that hands the pending job to the system task handler,
/// which runs on a background queue separate from the main actor.
private nonisolated final class JobBox: @unchecked Sendable {
  private let lock = NSLock()
  private var job: BackgroundExportCoordinator.Job?

  func set(_ job: BackgroundExportCoordinator.Job?) {
    lock.lock()
    self.job = job
    lock.unlock()
  }

  @discardableResult
  func take() -> BackgroundExportCoordinator.Job? {
    lock.lock()
    defer { lock.unlock() }
    let value = job
    job = nil
    return value
  }
}

/// Holds the in-flight export task so it can be cancelled from any context.
private nonisolated final class WorkHandle: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?

  func set(_ newTask: Task<Void, Never>?) {
    lock.lock()
    let old = task
    task = newTask
    lock.unlock()
    Self.cancelOffMain(old)
  }

  func cancel() {
    Self.cancelOffMain(take())
  }

  /// Cancels outside MainActor and returns only after media resources drain.
  func cancelAndWait() async {
    guard let current = take() else { return }

    await Task.detached(priority: .userInitiated) {
      current.cancel()
      await current.value
    }
    .value
  }

  private func take() -> Task<Void, Never>? {
    lock.lock()
    defer { lock.unlock() }
    let current = task
    task = nil
    return current
  }

  private static func cancelOffMain(_ task: Task<Void, Never>?) {
    guard let task else { return }
    // AVAssetReader cancellation can synchronously wait for a device Optical
    // Flow frame to finish. Keep that contract-correct drain off MainActor so
    // the export UI reacts immediately to Cancel.
    Task.detached(priority: .userInitiated) {
      task.cancel()
    }
  }
}

/// Bridges an expiration callback that may arrive before its Swift task exists.
///
/// `BGTask.expirationHandler` is installed before export work is created. If
/// expiration wins that race, attaching the work observes the sticky cancelled
/// state and cancels it immediately.
private nonisolated final class DeferredTaskCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var isCancelled = false
  private var task: Task<Void, Never>?

  func attach(_ newTask: Task<Void, Never>) {
    lock.lock()
    task = newTask
    let shouldCancel = isCancelled
    lock.unlock()

    if shouldCancel {
      newTask.cancel()
    }
  }

  func cancel() {
    lock.lock()
    isCancelled = true
    let current = task
    lock.unlock()
    current?.cancel()
  }

  func clear() {
    lock.lock()
    task = nil
    lock.unlock()
  }
}

/// Coalesces sample-level callbacks to a caller-selected progress resolution.
///
/// Foreground UI uses whole percentages, while continued processing uses finer
/// scheduler-visible units so a slow media pipeline does not appear stalled.
private nonisolated final class BatchProgressEmitter: @unchecked Sendable {
  private let lock = NSLock()
  private let itemCount: Int
  private let progressUnitCount: Int
  private let onProgress: @Sendable (VideoExportBatchProgress) -> Void
  private var lastCompletedUnit = -1
  private var lastItemIndex = -1

  init(
    itemCount: Int,
    progressUnitCount: Int,
    onProgress: @escaping @Sendable (VideoExportBatchProgress) -> Void
  ) {
    self.itemCount = itemCount
    self.progressUnitCount = max(progressUnitCount, 1)
    self.onProgress = onProgress
  }

  func update(itemIndex: Int, itemFraction: Double) {
    let progress = VideoExportBatchProgress(
      currentItemIndex: itemIndex,
      itemCount: itemCount,
      currentItemFraction: itemFraction
    )
    let completedUnit = Int(
      progress.overallFraction * Double(progressUnitCount)
    )

    lock.lock()
    let shouldEmit =
      completedUnit != lastCompletedUnit
      || itemIndex != lastItemIndex
    if shouldEmit {
      lastCompletedUnit = completedUnit
      lastItemIndex = itemIndex
    }
    lock.unlock()

    if shouldEmit {
      onProgress(progress)
    }
  }
}

/// Serializes access to a system continued-processing task across export tasks.
///
/// `BGContinuedProcessingTask` predates Swift's `Sendable` model even though
/// its progress is updated by asynchronous work. The unchecked boundary is
/// intentionally confined to this lock-protected adapter.
private nonisolated final class ContinuedProcessingTaskHandle: @unchecked Sendable {
  /// Finer than the visible percentage so sample progress remains observable.
  static let progressUnitCount = 10_000

  private let lock = NSLock()
  private let task: BGContinuedProcessingTask
  private var lastCompletedUnit: Int64 = -1
  private var lastPercent = -1
  private var lastItemIndex = -1

  init(_ task: BGContinuedProcessingTask) {
    self.task = task
    task.progress.totalUnitCount = Int64(Self.progressUnitCount)
  }

  /// Updates scheduler-visible progress and returns whether app UI should update.
  func updateProgress(_ progress: VideoExportBatchProgress) -> Bool {
    let completedUnit = Int64(
      progress.overallFraction * Double(Self.progressUnitCount)
    )
    let percent = Int(progress.overallFraction * 100)

    lock.lock()
    if completedUnit > lastCompletedUnit {
      lastCompletedUnit = completedUnit
      task.progress.completedUnitCount = completedUnit
    }
    let shouldUpdateVisibleProgress =
      percent != lastPercent
      || progress.currentItemIndex != lastItemIndex
    if shouldUpdateVisibleProgress {
      lastPercent = percent
      lastItemIndex = progress.currentItemIndex
      task.updateTitle(
        String(localized: "Exporting videos"),
        subtitle: String(
          localized:
            "Video \(progress.currentItemIndex + 1) of \(progress.itemCount) · \(percent)%",
          comment:
            "System background-task progress. Variables are current video, total videos, and overall percent."
        )
      )
    }
    lock.unlock()
    return shouldUpdateVisibleProgress
  }

  func complete(success: Bool) {
    lock.lock()
    task.setTaskCompleted(success: success)
    lock.unlock()
  }

  func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
    lock.lock()
    task.expirationHandler = handler
    lock.unlock()
  }
}
