//
//  OnDeviceTranscriptionManager.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2026/01/05.
//

import Foundation
import SwiftData
import TypedIdentifier
import YouTubeKit

/// Manager for on-device transcription using BackgroundTaskManager.
/// Uses in-memory state management (no SwiftData persistence).
@Observable
@MainActor
final class OnDeviceTranscriptionManager {

  // MARK: - Types

  enum TranscriptionPhase: Equatable {
    case pending
    case fetchingStreams
    case downloading(progress: Double)
    case transcribing(progress: Double)
  }

  struct TranscriptionProgress: Equatable {
    var phase: TranscriptionPhase
    var videoID: YouTubeContentID

    var overallProgress: Double {
      switch phase {
      case .pending, .fetchingStreams:
        return 0
      case .downloading(let p):
        // Download is 0-50% of overall progress
        return p * 0.5
      case .transcribing(let p):
        // Transcription is 50-100% of overall progress
        return 0.5 + p * 0.5
      }
    }
  }

  enum TranscriptionError: LocalizedError {
    case noStreamAvailable
    case downloadFailed(any Error)
    case transcriptionFailed(any Error)
    case cancelled

    var errorDescription: String? {
      switch self {
      case .noStreamAvailable:
        return "No compatible video stream found for transcription"
      case .downloadFailed(let error):
        return "Download failed: \(error.localizedDescription)"
      case .transcriptionFailed(let error):
        return "Transcription failed: \(error.localizedDescription)"
      case .cancelled:
        return "Transcription was cancelled"
      }
    }
  }

  // MARK: - Properties

  /// Active transcriptions (in-memory only)
  private(set) var activeTranscriptions: [TypedIdentifier<VideoItem>: TranscriptionProgress] = [:]

  /// Completion callback
  var onTranscriptionComplete: (
    (TypedIdentifier<VideoItem>, Result<Subtitle, any Error>) -> Void
  )?

  // MARK: - Private Properties

  private var activeTasks: [TypedIdentifier<VideoItem>: Task<Void, Never>] = [:]
  private let modelContainer: ModelContainer
  private let downloadManager: DownloadManager

  private static let taskIdentifierPrefix = "app.muukii.verse.transcription"

  /// Wrapper for safely passing MainActor-isolated references across concurrency boundaries.
  private final class SendableRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
  }

  /// Temporary directory for transcription files
  private var tempDirectory: URL {
    let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
    let dir = caches.appendingPathComponent("TranscriptionTemp", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  // MARK: - Initialization

  init(modelContainer: ModelContainer, downloadManager: DownloadManager) {
    self.modelContainer = modelContainer
    self.downloadManager = downloadManager
  }

  // MARK: - Public Methods

  /// Start transcription for a video item.
  /// - Parameters:
  ///   - itemID: Video item identifier
  ///   - videoID: YouTube video ID
  ///   - configuration: Transcription configuration
  func startTranscription(
    itemID: TypedIdentifier<VideoItem>,
    videoID: YouTubeContentID,
    configuration: OnDeviceTranscribeConfiguration = .default
  ) {
    // Don't start if already transcribing
    guard !isTranscribing(itemID: itemID) else { return }

    // Initialize progress state
    activeTranscriptions[itemID] = TranscriptionProgress(
      phase: .pending,
      videoID: videoID
    )

    // Create task identifier
    let taskIdentifier = Self.taskIdentifierPrefix + "." + itemID.raw.uuidString

    // Wrap self for safe sending across concurrency boundaries
    let selfRef = SendableRef(self)

    // Schedule continued background task using BackgroundTaskManager (with Live Activity support)
    BackgroundTaskManager.shared.scheduleContinued(
      identifier: taskIdentifier,
      configuration: .init(title: "Transcribing", subtitle: "Processing video...")
    ) { context in
      // Run transcription on MainActor
      await MainActor.run {
        guard let manager = selfRef.value else { return }

        // Create and store the task
        let task = Task {
          await manager.runTranscription(
            itemID: itemID,
            videoID: videoID,
            configuration: configuration,
            context: context
          )
        }
        manager.activeTasks[itemID] = task
      }

      // Wait for the task to complete
      if let task = await MainActor.run(body: { selfRef.value?.activeTasks[itemID] }) {
        await task.value
      }
    }
  }

  /// Cancel an active transcription.
  /// - Parameter itemID: Video item identifier
  func cancelTranscription(itemID: TypedIdentifier<VideoItem>) {
    let taskIdentifier = Self.taskIdentifierPrefix + "." + itemID.raw.uuidString
    BackgroundTaskManager.shared.cancel(identifier: taskIdentifier)

    activeTasks[itemID]?.cancel()
    activeTasks.removeValue(forKey: itemID)
    activeTranscriptions.removeValue(forKey: itemID)
  }

  /// Check if transcription is in progress for an item.
  /// - Parameter itemID: Video item identifier
  /// - Returns: True if transcription is active
  func isTranscribing(itemID: TypedIdentifier<VideoItem>) -> Bool {
    activeTranscriptions[itemID] != nil
  }

  /// Get progress for a specific item.
  /// - Parameter itemID: Video item identifier
  /// - Returns: Transcription progress if active
  func progress(for itemID: TypedIdentifier<VideoItem>) -> TranscriptionProgress? {
    activeTranscriptions[itemID]
  }

  private func runTranscription(
    itemID: TypedIdentifier<VideoItem>,
    videoID: YouTubeContentID,
    configuration: OnDeviceTranscribeConfiguration,
    context: BackgroundTaskManager.TaskContext
  ) async {
    var tempFileURL: URL?

    do {
      // Phase 1: Fetch streams
      updatePhase(itemID: itemID, phase: .fetchingStreams)

      try Task.checkCancellation()
      guard !context.isCancelled else { throw TranscriptionError.cancelled }

      let stream = try await YouTubeStreamService.fetchAndSelect(
        videoID: videoID,
        strategy: configuration.streamStrategy
      )

      guard let stream = stream else {
        throw TranscriptionError.noStreamAvailable
      }

      let streamURL = stream.url

      // Phase 2: Download
      updatePhase(itemID: itemID, phase: .downloading(progress: 0))

      try Task.checkCancellation()
      guard !context.isCancelled else { throw TranscriptionError.cancelled }

      let fileExtension = stream.fileExtension.rawValue
      let downloadedURL = try await downloadManager.downloadTemporary(
        streamURL: streamURL,
        videoID: videoID,
        fileExtension: fileExtension,
        progressHandler: { [weak self] progress in
          self?.updatePhase(itemID: itemID, phase: .downloading(progress: progress))
          context.reportProgress(progress * 0.5)  // 0-50%
        }
      )

      tempFileURL = downloadedURL

      // Phase 3: Transcribe
      updatePhase(itemID: itemID, phase: .transcribing(progress: 0))

      try Task.checkCancellation()
      guard !context.isCancelled else { throw TranscriptionError.cancelled }

      let subtitle = try await TranscriptionService.shared.transcribe(
        fileURL: downloadedURL,
        locale: configuration.transcriptionLocale
      ) { [weak self] state in
        switch state {
        case .transcribing(let progress):
          self?.updatePhase(itemID: itemID, phase: .transcribing(progress: progress))
          context.reportProgress(0.5 + progress * 0.5)  // 50-100%
        default:
          break
        }
      }

      // Success - cleanup and notify
      cleanupTempFile(at: tempFileURL)
      completeTranscription(itemID: itemID, result: .success(subtitle))

    } catch is CancellationError {
      cleanupTempFile(at: tempFileURL)
      completeTranscription(itemID: itemID, result: .failure(TranscriptionError.cancelled))

    } catch {
      cleanupTempFile(at: tempFileURL)
      completeTranscription(itemID: itemID, result: .failure(error))
    }
  }

  private func updatePhase(itemID: TypedIdentifier<VideoItem>, phase: TranscriptionPhase) {
    guard var progress = activeTranscriptions[itemID] else { return }
    progress.phase = phase
    activeTranscriptions[itemID] = progress
  }

  private func completeTranscription(
    itemID: TypedIdentifier<VideoItem>,
    result: Result<Subtitle, any Error>
  ) {
    // Remove from active state
    activeTranscriptions.removeValue(forKey: itemID)
    activeTasks.removeValue(forKey: itemID)

    // Notify completion
    onTranscriptionComplete?(itemID, result)
  }

  private func cleanupTempFile(at url: URL?) {
    guard let url = url else { return }
    try? FileManager.default.removeItem(at: url)
  }
}

