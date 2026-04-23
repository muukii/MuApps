//
//  DownloadManager.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/12/05.
//

@preconcurrency import BackgroundTasks
import Foundation
import SwiftData
import TypedIdentifier
import YouTubeKit

// MARK: - Download State (for UI)

/// UI state representation for downloads.
/// Note: This is different from DownloadStateEntity.Status which is for persistence.
enum DownloadState: String, Sendable {
  case pending
  case downloading
  case completed
  case failed
  case cancelled
}

// MARK: - Download Progress

struct DownloadProgress: Sendable {
  let itemID: TypedIdentifier<VideoItem>
  let videoID: YouTubeContentID
  let videoTitle: String?
  var fractionCompleted: Double
  var state: DownloadState
}

// MARK: - Download Error

enum DownloadError: LocalizedError {
  case invalidURL
  case taskExpired
  case noData
  case fileWriteFailed(any Error)
  case cancelled
  case videoItemNotFound
  case downloadStateNotFound

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      return "Invalid download URL"
    case .taskExpired:
      return "Download was interrupted by the system"
    case .noData:
      return "No data received"
    case .fileWriteFailed(let error):
      return "Failed to save file: \(error.localizedDescription)"
    case .cancelled:
      return "Download was cancelled"
    case .videoItemNotFound:
      return "Video item not found"
    case .downloadStateNotFound:
      return "Download state not found"
    }
  }
}

// MARK: - Download Session Delegate

/// Handles URLSessionDownloadTask delegate callbacks and bridges to async/await.
private final class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

  struct ProgressUpdate: Sendable {
    let bytesWritten: Int64
    let totalBytesWritten: Int64
    let totalBytesExpectedToWrite: Int64

    var fractionCompleted: Double {
      guard totalBytesExpectedToWrite > 0 else { return 0 }
      return Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }
  }

  enum DownloadEvent: Sendable {
    case progress(ProgressUpdate)
    case completed(URL)
    case failed(any Error)
  }

  private let continuation: AsyncStream<DownloadEvent>.Continuation
  private let destinationURL: URL

  init(continuation: AsyncStream<DownloadEvent>.Continuation, destinationURL: URL) {
    self.continuation = continuation
    self.destinationURL = destinationURL
    super.init()
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    let update = ProgressUpdate(
      bytesWritten: bytesWritten,
      totalBytesWritten: totalBytesWritten,
      totalBytesExpectedToWrite: totalBytesExpectedToWrite
    )
    continuation.yield(.progress(update))
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {
    // IMPORTANT: Must move file immediately - temp file is deleted when this method returns
    do {
      // Remove existing file if any
      try? FileManager.default.removeItem(at: destinationURL)
      try FileManager.default.moveItem(at: location, to: destinationURL)
      continuation.yield(.completed(destinationURL))
    } catch {
      continuation.yield(.failed(DownloadError.fileWriteFailed(error)))
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    if let error {
      continuation.yield(.failed(error))
    }
    continuation.finish()
  }
}

// MARK: - Download Manager

/// Manages video downloads using BGContinuedProcessingTask for background execution.
/// Progress is automatically displayed in Live Activity.
@Observable
@MainActor
final class DownloadManager: Sendable {

  // MARK: - Observable State

  /// Active downloads with their progress (for UI observation)
  private(set) var activeDownloads: [TypedIdentifier<VideoItem>: DownloadProgress] = [:]

  /// Pending downloads in queue
  private(set) var pendingItemIDs: [TypedIdentifier<VideoItem>] = []

  // MARK: - Constants

  /// Static task identifier registered in Info.plist
  private static let taskIdentifier = "app.muukii.verse.download"

  // MARK: - Private Properties

  private let scheduler = BGTaskScheduler.shared
  private let modelContainer: ModelContainer
  private var activeTask: BGContinuedProcessingTask?
  private var downloadTasks: [TypedIdentifier<VideoItem>: Task<Void, Never>] = [:]
  private var urlSessionTasks: [TypedIdentifier<VideoItem>: URLSessionDownloadTask] = [:]
  private var isTaskRegistered = false

  // MARK: - Initialization

  init(
    modelContainer: ModelContainer
  ) {
    self.modelContainer = modelContainer
  }

  // MARK: - Public API

  /// Queue a new download for the specified video and stream.
  /// Returns the VideoItem ID for tracking.
  @discardableResult
  func queueDownload(
    videoID: YouTubeContentID,
    stream: YouTubeKit.Stream
  ) async throws -> TypedIdentifier<VideoItem> {

    // Fetch VideoItem
    let context = ModelContext(modelContainer)
    let videoIDRaw = videoID.rawValue
    let descriptor = FetchDescriptor<VideoItem>(
      predicate: #Predicate { $0._videoID == videoIDRaw }
    )
    guard let item = try? context.fetch(descriptor).first else {
      throw DownloadError.videoItemNotFound
    }

    // Create DownloadStateEntity and attach to VideoItem
    let entity = DownloadStateEntity(
      streamURL: stream.url.absoluteString,
      fileExtension: stream.fileExtension.rawValue
    )
    item.downloadState = entity
    context.insert(entity)

    try context.save()

    let itemID = item.typedID

    // Update observable state
    activeDownloads[itemID] = DownloadProgress(
      itemID: itemID,
      videoID: videoID,
      videoTitle: item.title,
      fractionCompleted: 0,
      state: .pending
    )
    pendingItemIDs.append(itemID)

    // Try to submit BGTask, fall back to foreground download if unavailable
    do {
      try submitTask(for: itemID)
    } catch {
      // BGTask unavailable (e.g., simulator), run foreground download
      print("BGTask unavailable, falling back to foreground download: \(error)")
      startDownload(itemID: itemID, bgTask: nil)
    }

    return itemID
  }

  /// Cancel a specific download.
  func cancelDownload(itemID: TypedIdentifier<VideoItem>) {
    // Cancel the URLSession download task
    urlSessionTasks[itemID]?.cancel()
    urlSessionTasks[itemID] = nil

    // Cancel the Swift Task
    downloadTasks[itemID]?.cancel()
    downloadTasks[itemID] = nil

    // Delete DownloadStateEntity
    Task {
      await deleteDownloadState(itemID: itemID)
    }

    // Remove from active downloads
    activeDownloads.removeValue(forKey: itemID)
    pendingItemIDs.removeAll { $0 == itemID }
  }

  /// Cancel all downloads for a specific video ID.
  /// Call this when deleting a VideoItem.
  func cancelDownloads(for videoID: YouTubeContentID) {
    let itemsToCancel = activeDownloads.filter { $0.value.videoID == videoID }
    for (itemID, _) in itemsToCancel {
      cancelDownload(itemID: itemID)
    }
  }

  /// Resume a paused download.
  /// - Note: Currently not implemented. Paused downloads need to be restarted.
  func resumeDownload(itemID: TypedIdentifier<VideoItem>) {
    // TODO: Implement resume functionality
    // For now, this is a no-op as the download system doesn't support pause/resume yet
  }

  /// Get download progress for a specific video ID.
  func downloadProgress(for videoID: YouTubeContentID) -> DownloadProgress? {
    activeDownloads.values.first { $0.videoID == videoID }
  }

  // MARK: - Temporary Download (for transcription)

  /// Download a video temporarily for transcription purposes.
  /// - The file is saved to NSTemporaryDirectory()
  /// - No SwiftData persistence (caller is responsible for cleanup)
  /// - Progress is reported via callback
  /// - Parameters:
  ///   - streamURL: URL of the video stream to download
  ///   - videoID: Video ID for filename generation
  ///   - fileExtension: File extension (e.g., "mp4")
  ///   - progressHandler: Callback for progress updates (0.0 to 1.0)
  /// - Returns: URL of the downloaded temporary file
  func downloadTemporary(
    streamURL: URL,
    videoID: YouTubeContentID,
    fileExtension: String,
    progressHandler: @MainActor @escaping (Double) -> Void
  ) async throws -> URL {
    // Prepare destination file path in temporary directory
    let tempDir = FileManager.default.temporaryDirectory
    let fileName = "\(videoID.rawValue)_temp_\(UUID().uuidString).\(fileExtension)"
    let destinationURL = tempDir.appendingPathComponent(fileName)

    // Create AsyncStream for delegate events
    var downloadDelegate: DownloadSessionDelegate?
    let eventStream = AsyncStream<DownloadSessionDelegate.DownloadEvent> { continuation in
      downloadDelegate = DownloadSessionDelegate(
        continuation: continuation,
        destinationURL: destinationURL
      )
    }

    // Create URLSession with delegate
    let session = URLSession(
      configuration: .default,
      delegate: downloadDelegate,
      delegateQueue: nil
    )

    // Start download task
    let downloadTask = session.downloadTask(with: streamURL)
    downloadTask.resume()

    // Track for progress throttling
    var lastProgressUpdate = Date()
    var finalURL: URL?

    // Process events from delegate
    for await event in eventStream {
      try Task.checkCancellation()

      switch event {
      case .progress(let update):
        // Throttle progress updates
        let now = Date()
        if now.timeIntervalSince(lastProgressUpdate) >= 0.3 {
          lastProgressUpdate = now
          progressHandler(update.fractionCompleted)
        }

      case .completed(let movedURL):
        finalURL = movedURL

      case .failed(let error):
        session.invalidateAndCancel()
        throw error
      }
    }

    session.finishTasksAndInvalidate()

    guard let resultURL = finalURL else {
      throw DownloadError.noData
    }

    return resultURL
  }

  /// Restore pending downloads on app launch.
  /// Call this after configure(modelContainer:).
  func restorePendingDownloads() async {

    let context = ModelContext(modelContainer)
    // Find VideoItems that have active download state
    let descriptor = FetchDescriptor<VideoItem>()

    guard let items = try? context.fetch(descriptor) else { return }

    // Filter items with downloadState
    let pendingItems = items.filter { $0.downloadState != nil }

    for item in pendingItems {
      guard let downloadState = item.downloadState else { continue }

      activeDownloads[item.typedID] = DownloadProgress(
        itemID: item.typedID,
        videoID: item.videoID,
        videoTitle: item.title,
        fractionCompleted: 0,
        state: downloadState.status == .pending ? .pending : .downloading
      )

      if downloadState.status == .pending {
        pendingItemIDs.append(item.typedID)
      }
    }

    // Submit tasks for all pending downloads
    for itemID in pendingItemIDs {
      do {
        try submitTask(for: itemID)
      } catch {
        // BGTask unavailable, fall back to foreground download
        print("BGTask unavailable for restored download, falling back to foreground: \(error)")
        startDownload(itemID: itemID, bgTask: nil)
        break // Only start one foreground download at a time
      }
    }
  }

  // MARK: - BGTask Management

  /// Handle the background task for a specific download.
  private func handleBackgroundTask(_ task: BGContinuedProcessingTask, itemID: TypedIdentifier<VideoItem>) async {
    // Track active task
    activeTask = task

    // Set up expiration handler
    var wasExpired = false
    task.expirationHandler = { [weak self] in
      wasExpired = true
      Task { @MainActor in
        self?.downloadTasks[itemID]?.cancel()
      }
    }

    // Configure progress reporting for Live Activity
    task.progress.totalUnitCount = 100

    // Execute download
    startDownload(itemID: itemID, bgTask: task, checkExpired: { wasExpired })

    // Wait for download to complete
    await downloadTasks[itemID]?.value

    // Cleanup
    activeTask = nil
    task.setTaskCompleted(success: true)

    // Remove from pending
    pendingItemIDs.removeAll { $0 == itemID }
  }

  /// Submit a task request for a specific download.
  private func submitTask(for itemID: TypedIdentifier<VideoItem>) throws {
    guard let progress = activeDownloads[itemID] else { return }

    let fullIdentifier = Self.taskIdentifier + ".\(itemID.raw.uuidString)"

    // Dynamically register handler for this specific task identifier
    scheduler.register(forTaskWithIdentifier: fullIdentifier, using: nil) { @Sendable [weak self] task in
      guard let bgTask = task as? BGContinuedProcessingTask else { return }

      Task { @MainActor [weak self, bgTask] in
        await self?.handleBackgroundTask(bgTask, itemID: itemID)
      }
    }

    // Use video title if available, otherwise generic title
    let title = progress.videoTitle ?? "Downloading video"
    let subtitle = "YouTube: \(progress.videoID)"

    let request = BGContinuedProcessingTaskRequest(
      identifier: fullIdentifier,
      title: title,
      subtitle: subtitle
    )
    request.strategy = .queue

    try scheduler.submit(request)
  }

  // MARK: - Unified Download Execution

  /// Start a download task (unified for both foreground and BGTask).
  private func startDownload(
    itemID: TypedIdentifier<VideoItem>,
    bgTask: BGContinuedProcessingTask?,
    checkExpired: @escaping () -> Bool = { false }
  ) {
    let downloadTask = Task { [weak self] in
      guard let self else { return }
      await self.performDownload(
        itemID: itemID,
        bgTask: bgTask,
        checkExpired: checkExpired
      )
    }
    downloadTasks[itemID] = downloadTask
  }

  /// Perform the download (unified for both foreground and BGTask).
  private func performDownload(
    itemID: TypedIdentifier<VideoItem>,
    bgTask: BGContinuedProcessingTask?,
    checkExpired: @escaping () -> Bool
  ) async {

    // Fetch item
    let context = ModelContext(modelContainer)
    let rawID = itemID.raw
    let descriptor = FetchDescriptor<VideoItem>(
      predicate: #Predicate { $0.id == rawID }
    )
    guard let item = try? context.fetch(descriptor).first else { return }

    // Get download state entity
    guard let downloadStateEntity = item.downloadState else {
      await markFailed(itemID: itemID, context: context)
      return
    }

    // Update state to downloading
    downloadStateEntity.status = .downloading
    try? context.save()
    updateProgress(itemID: itemID, fraction: 0, state: .downloading)

    // Parse URL
    guard let url = URL(string: downloadStateEntity.streamURL) else {
      await markFailed(itemID: itemID, context: context)
      return
    }

    let fileExtension = downloadStateEntity.fileExtension

    do {
      // Download with progress using URLSessionDownloadTask
      let destinationURL = try await downloadFile(
        from: url,
        videoID: item.videoID,
        fileExtension: fileExtension,
        itemID: itemID,
        bgTask: bgTask,
        checkExpired: checkExpired
      )

      // Mark as completed
      item.downloadedFileName = destinationURL.lastPathComponent

      // Delete DownloadStateEntity (download complete)
      if let entity = item.downloadState {
        context.delete(entity)
      }
      item.downloadState = nil

      try? context.save()

      // Update progress to 100% before removing
      updateProgress(itemID: itemID, fraction: 1.0, state: .completed)

      // Remove from active downloads - UI will now use item.downloadedFileName
      activeDownloads.removeValue(forKey: itemID)
      pendingItemIDs.removeAll { $0 == itemID }
      downloadTasks.removeValue(forKey: itemID)

      // Process next in queue (only for foreground downloads)
      if bgTask == nil, let nextID = pendingItemIDs.first {
        startDownload(itemID: nextID, bgTask: nil)
      }

    } catch is CancellationError {
      // Delete DownloadStateEntity (cancelled)
      if let entity = item.downloadState {
        context.delete(entity)
      }
      item.downloadState = nil
      try? context.save()

      activeDownloads.removeValue(forKey: itemID)
      downloadTasks.removeValue(forKey: itemID)

    } catch {
      await markFailed(itemID: itemID, context: context)
      downloadTasks.removeValue(forKey: itemID)
    }
  }

  /// Download file using URLSessionDownloadTask (efficient, runs in background).
  private func downloadFile(
    from url: URL,
    videoID: YouTubeContentID,
    fileExtension: String,
    itemID: TypedIdentifier<VideoItem>,
    bgTask: BGContinuedProcessingTask?,
    checkExpired: @escaping () -> Bool
  ) async throws -> URL {

    // Prepare destination file path
    let fileName = "\(videoID).\(fileExtension)"
    let destinationURL = URL.documentsDirectory.appendingPathComponent(fileName)

    // Create AsyncStream for delegate events
    // Pass destinationURL to delegate so it can move file immediately in callback
    var downloadDelegate: DownloadSessionDelegate?
    let eventStream = AsyncStream<DownloadSessionDelegate.DownloadEvent> { continuation in
      downloadDelegate = DownloadSessionDelegate(
        continuation: continuation,
        destinationURL: destinationURL
      )
    }

    // Create URLSession with delegate
    let session = URLSession(
      configuration: .default,
      delegate: downloadDelegate,
      delegateQueue: nil  // Use system queue for callbacks
    )

    // Start download task
    let downloadTask = session.downloadTask(with: url)
    urlSessionTasks[itemID] = downloadTask
    downloadTask.resume()

    // Track for progress throttling
    var lastProgressUpdate = Date()
    var finalURL: URL?

    // Process events from delegate
    for await event in eventStream {
      // Check for cancellation or expiration
      try Task.checkCancellation()
      if checkExpired() {
        downloadTask.cancel()
        throw DownloadError.taskExpired
      }

      switch event {
      case .progress(let update):
        // Throttle progress updates to avoid excessive main thread work
        let now = Date()
        if now.timeIntervalSince(lastProgressUpdate) >= 0.3 {
          lastProgressUpdate = now

          let fraction = update.fractionCompleted

          // Update Live Activity progress (if BGTask)
          if let bgTask {
            bgTask.progress.completedUnitCount = Int64(fraction * 100)
            bgTask.updateTitle("Downloading video", subtitle: "\(Int(fraction * 100))%")
          }

          // Update observable state on main thread
          updateProgress(itemID: itemID, fraction: fraction, state: .downloading)
        }

      case .completed(let movedURL):
        // File was already moved to destination in delegate callback
        finalURL = movedURL

      case .failed(let error):
        urlSessionTasks[itemID] = nil
        session.invalidateAndCancel()
        throw error
      }
    }

    // Clean up
    urlSessionTasks[itemID] = nil
    session.finishTasksAndInvalidate()

    guard let resultURL = finalURL else {
      throw DownloadError.noData
    }

    return resultURL
  }

  // MARK: - Helpers

  private func updateProgress(itemID: TypedIdentifier<VideoItem>, fraction: Double, state: DownloadState) {
    if var progress = activeDownloads[itemID] {
      progress.fractionCompleted = fraction
      progress.state = state
      activeDownloads[itemID] = progress
    }
  }

  private func markFailed(
    itemID: TypedIdentifier<VideoItem>,
    context: ModelContext
  ) async {
    let rawID = itemID.raw
    let descriptor = FetchDescriptor<VideoItem>(
      predicate: #Predicate { $0.id == rawID }
    )
    if let item = try? context.fetch(descriptor).first {
      // Delete DownloadStateEntity (failed)
      if let entity = item.downloadState {
        context.delete(entity)
      }
      item.downloadState = nil
      try? context.save()
    }

    updateProgress(itemID: itemID, fraction: 0, state: .failed)
    pendingItemIDs.removeAll { $0 == itemID }
  }

  private func deleteDownloadState(itemID: TypedIdentifier<VideoItem>) async {
    let context = ModelContext(modelContainer)
    let rawID = itemID.raw
    let descriptor = FetchDescriptor<VideoItem>(
      predicate: #Predicate { $0.id == rawID }
    )
    if let item = try? context.fetch(descriptor).first {
      if let entity = item.downloadState {
        context.delete(entity)
      }
      item.downloadState = nil
      try? context.save()
    }
  }
}
