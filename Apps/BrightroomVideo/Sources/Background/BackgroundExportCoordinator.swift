//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BackgroundTasks
import BrightroomParametric
import Foundation

/// Coordinates video export using iOS 26's `BGContinuedProcessingTask` so a
/// render started in the foreground keeps running — with system progress UI —
/// after the user leaves the app, then saves the result to Photos.
///
/// When the continued-processing task can't be scheduled (e.g. on the
/// Simulator), it transparently falls back to a foreground export so the app
/// still works everywhere. `activePath` records which one is live so the UI can
/// tell the truth about whether the user may leave the app.
@MainActor
@Observable
final class BackgroundExportCoordinator {

  /// The single permitted task identifier (see `BGTaskSchedulerPermittedIdentifiers`).
  static let taskIdentifier = "app.muukii.brightroom.BrightroomVideo.export"

  static let shared = BackgroundExportCoordinator()

  enum Phase: Equatable {
    case idle
    case exporting(Double)
    case finished(url: URL, savedToPhotos: Bool)
    case failed(String)
  }

  enum ActivePath: Equatable {
    /// Running as a `BGContinuedProcessingTask` — safe to leave the app.
    case background
    /// Foreground fallback — the app must stay open.
    case foreground
  }

  private(set) var phase: Phase = .idle
  private(set) var activePath: ActivePath?

  var isBackgroundExport: Bool { activePath == .background }

  /// The export strategy. Nonisolated so the background task handler can use it.
  private nonisolated let exporter: any VideoExporting = ParametricVideoExporter()

  /// Holds the job for the system-launched task handler to pick up.
  private nonisolated let jobBox = JobBox()

  /// The in-flight export work, so an explicit cancel can stop it.
  private nonisolated let workHandle = WorkHandle()

  private var didRegister = false

  // MARK: - Launch registration

  /// Registers the task handler. Call once, at app launch.
  func registerHandler() {
    guard didRegister == false else { return }
    didRegister = true

    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.taskIdentifier,
      using: nil
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

  /// Starts an export, preferring the background-continuable task.
  func start(asset: AVURLAsset, document: EditingDocument, colorInfo: VideoColorInfo) {
    guard case .idle = phase else { return }

    let job = Job(
      asset: asset,
      document: document,
      colorInfo: colorInfo,
      outputURL: Self.makeOutputURL()
    )
    Self.cleanupExportsDirectory(keeping: job.outputURL)
    phase = .exporting(0)

    let request = BGContinuedProcessingTaskRequest(
      identifier: Self.taskIdentifier,
      title: "Exporting video",
      subtitle: "Applying your LUT…"
    )
    request.strategy = .queue
    if BGTaskScheduler.supportedResources.contains(.gpu) {
      request.requiredResources = .gpu
    }

    jobBox.set(job)
    do {
      try BGTaskScheduler.shared.submit(request)
      activePath = .background
      // The system invokes the registered handler, which drives `run(task:job:)`.
    } catch {
      // Unsupported here (e.g. Simulator) — run in the foreground instead.
      jobBox.take()
      activePath = .foreground
      runForeground(job: job)
    }
  }

  /// Clears finished/failed state so a new export can start. No-op cancel if idle.
  func reset() {
    workHandle.cancel()
    jobBox.take()
    phase = .idle
    activePath = nil
  }

  /// Explicitly aborts an in-flight export (background or foreground).
  func cancel() {
    workHandle.cancel()
    jobBox.take()
    if case .exporting = phase {
      phase = .idle
    }
    activePath = nil
  }

  // MARK: - Background execution (system task handler)

  private nonisolated func run(task: BGContinuedProcessingTask, job: Job) {
    let taskHandle = ContinuedProcessingTaskHandle(task)

    let work = Task { [exporter, taskHandle] in
      do {
        try await exporter.export(
          asset: job.asset,
          document: job.document,
          colorInfo: job.colorInfo,
          to: job.outputURL
        ) { fraction in
          taskHandle.updateProgress(fraction)
          Task { @MainActor in BackgroundExportCoordinator.shared.update(fraction: fraction) }
        }
        let saved = await Self.saveToPhotos(job.outputURL)
        await MainActor.run {
          BackgroundExportCoordinator.shared.finish(.finished(url: job.outputURL, savedToPhotos: saved))
        }
        taskHandle.complete(success: true)
      } catch is CancellationError {
        Self.removeFile(job.outputURL)
        await MainActor.run { BackgroundExportCoordinator.shared.markCancelled() }
        taskHandle.complete(success: false)
      } catch {
        Self.removeFile(job.outputURL)
        await MainActor.run {
          BackgroundExportCoordinator.shared.finish(.failed(error.localizedDescription))
        }
        taskHandle.complete(success: false)
      }
    }

    workHandle.set(work)
    taskHandle.setExpirationHandler { work.cancel() }
  }

  // MARK: - Foreground fallback

  private func runForeground(job: Job) {
    let work = Task { [exporter] in
      do {
        try await exporter.export(
          asset: job.asset,
          document: job.document,
          colorInfo: job.colorInfo,
          to: job.outputURL
        ) { fraction in
          Task { @MainActor in BackgroundExportCoordinator.shared.update(fraction: fraction) }
        }
        let saved = await Self.saveToPhotos(job.outputURL)
        finish(.finished(url: job.outputURL, savedToPhotos: saved))
      } catch is CancellationError {
        Self.removeFile(job.outputURL)
        markCancelled()
      } catch {
        Self.removeFile(job.outputURL)
        finish(.failed(error.localizedDescription))
      }
    }
    workHandle.set(work)
  }

  // MARK: - Phase updates

  /// Monotonic progress: never regress, even if out-of-order ticks arrive.
  fileprivate func update(fraction: Double) {
    guard case .exporting(let current) = phase else { return }
    if fraction >= current {
      phase = .exporting(fraction)
    }
  }

  fileprivate func finish(_ newPhase: Phase) {
    phase = newPhase
    activePath = nil
  }

  fileprivate func markCancelled() {
    phase = .idle
    activePath = nil
  }

  // MARK: - Helpers

  private static func saveToPhotos(_ url: URL) async -> Bool {
    do {
      try await PhotoLibrarySaver.save(videoAt: url)
      return true
    } catch {
      return false
    }
  }

  private nonisolated static func cachesExportsDirectory() -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Exports", isDirectory: true)
  }

  static func makeOutputURL() -> URL {
    let directory = cachesExportsDirectory()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("BrightroomVideo-\(UUID().uuidString).mov")
  }

  /// Removes previously exported files (already shared/saved) to bound storage.
  private nonisolated static func cleanupExportsDirectory(keeping keepURL: URL) {
    let directory = cachesExportsDirectory()
    guard
      let files = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
      )
    else {
      return
    }
    for file in files where file != keepURL {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private nonisolated static func removeFile(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
  }

  struct Job {
    let asset: AVURLAsset
    let document: EditingDocument
    let colorInfo: VideoColorInfo
    let outputURL: URL
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
    old?.cancel()
  }

  func cancel() {
    lock.lock()
    let current = task
    task = nil
    lock.unlock()
    current?.cancel()
  }
}

/// Serializes access to a system continued-processing task across export tasks.
///
/// `BGContinuedProcessingTask` predates Swift's `Sendable` model even though
/// BackgroundTasks delivers it on a non-main queue and its progress is updated
/// by asynchronous work. The unchecked boundary is intentionally confined to
/// this lock-protected adapter.
private nonisolated final class ContinuedProcessingTaskHandle: @unchecked Sendable {
  private let lock = NSLock()
  private let task: BGContinuedProcessingTask
  private var lastPercent = -1

  init(_ task: BGContinuedProcessingTask) {
    self.task = task
    task.progress.totalUnitCount = 100
  }

  func updateProgress(_ fraction: Double) {
    let percent = Int(fraction * 100)

    lock.lock()
    task.progress.completedUnitCount = Int64(percent)
    if percent != lastPercent {
      lastPercent = percent
      task.updateTitle("Exporting video", subtitle: "\(percent)%")
    }
    lock.unlock()
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
