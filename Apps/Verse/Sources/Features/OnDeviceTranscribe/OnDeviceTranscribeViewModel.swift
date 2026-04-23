//
//  OnDeviceTranscribeViewModel.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/09.
//

import Foundation
@preconcurrency import YouTubeKit

// MARK: - Error Types

enum OnDeviceTranscribeError: LocalizedError {
  case noCompatibleStream
  case streamFetchFailed(any Error)
  case downloadFailed(any Error)
  case transcriptionFailed(any Error)
  case cancelled

  var errorDescription: String? {
    switch self {
    case .noCompatibleStream:
      return "No compatible video stream found. This video may not support on-device transcription."
    case .streamFetchFailed(let error):
      return "Failed to fetch video streams: \(error.localizedDescription)"
    case .downloadFailed(let error):
      return "Download failed: \(error.localizedDescription)"
    case .transcriptionFailed(let error):
      return "Transcription failed: \(error.localizedDescription)"
    case .cancelled:
      return "Operation was cancelled"
    }
  }
}

// MARK: - Configuration

struct OnDeviceTranscribeConfiguration {
  /// Strategy for selecting video stream quality
  var streamStrategy: StreamSelectionStrategy = .medium

  /// Locale for speech recognition
  var transcriptionLocale: Locale = .current

  static let `default` = OnDeviceTranscribeConfiguration()
}

// MARK: - ViewModel

@Observable
@MainActor
final class OnDeviceTranscribeViewModel {

  // MARK: - Phase

  enum Phase: Equatable {
    case idle
    case fetchingStreams
    case downloading(progress: Double)
    case transcribing(progress: Double)
    case completed
    case failed(String)

    static func == (lhs: Phase, rhs: Phase) -> Bool {
      switch (lhs, rhs) {
      case (.idle, .idle): return true
      case (.fetchingStreams, .fetchingStreams): return true
      case (.downloading(let p1), .downloading(let p2)): return p1 == p2
      case (.transcribing(let p1), .transcribing(let p2)): return p1 == p2
      case (.completed, .completed): return true
      case (.failed(let m1), .failed(let m2)): return m1 == m2
      default: return false
      }
    }

    var isProcessing: Bool {
      switch self {
      case .fetchingStreams, .downloading, .transcribing:
        return true
      case .idle, .completed, .failed:
        return false
      }
    }
  }

  // MARK: - Properties

  private(set) var phase: Phase = .idle
  private(set) var configuration: OnDeviceTranscribeConfiguration
  private var downloadedFileURL: URL?
  private var currentTask: Task<Subtitle, any Error>?

  // MARK: - Initialization

  init(configuration: OnDeviceTranscribeConfiguration = .default) {
    self.configuration = configuration
  }

  // MARK: - Public Methods

  /// Starts the on-device transcription workflow.
  /// - Parameters:
  ///   - videoID: YouTube video ID
  ///   - downloadManager: DownloadManager instance for temporary download
  /// - Returns: Generated subtitles
  func startTranscription(
    videoID: YouTubeContentID,
    downloadManager: DownloadManager
  ) async throws -> Subtitle {
    // Store task for cancellation support
    let task = Task { @MainActor [weak self] () throws -> Subtitle in
      guard let self else { throw OnDeviceTranscribeError.cancelled }

      do {
        // 1. Fetch streams using shared service
        phase = .fetchingStreams
        let streams: [YouTubeKit.Stream]
        do {
          streams = try await YouTubeStreamService.fetchStreams(videoID: videoID)
        } catch {
          throw OnDeviceTranscribeError.streamFetchFailed(error)
        }

        // 2. Select stream based on configuration strategy
        guard let stream = YouTubeStreamService.selectStream(
          from: streams,
          strategy: configuration.streamStrategy
        ) else {
          throw OnDeviceTranscribeError.noCompatibleStream
        }

        // 3. Download temporarily
        do {
          downloadedFileURL = try await downloadManager.downloadTemporary(
            streamURL: stream.url,
            videoID: videoID,
            fileExtension: stream.fileExtension.rawValue
          ) { [weak self] progress in
            self?.phase = .downloading(progress: progress)
          }
        } catch {
          throw OnDeviceTranscribeError.downloadFailed(error)
        }

        guard let fileURL = downloadedFileURL else {
          throw OnDeviceTranscribeError.downloadFailed(DownloadError.noData)
        }

        // 4. Transcribe using existing service
        let subtitles: Subtitle
        do {
          subtitles = try await TranscriptionService.shared.transcribe(
            fileURL: fileURL,
            locale: configuration.transcriptionLocale
          ) { [weak self] state in
            switch state {
            case .preparingAssets:
              self?.phase = .transcribing(progress: 0)
            case .transcribing(let progress):
              self?.phase = .transcribing(progress: progress)
            case .completed, .idle, .failed:
              break
            }
          }
        } catch {
          throw OnDeviceTranscribeError.transcriptionFailed(error)
        }

        // 5. Cleanup and complete
        cleanup()
        phase = .completed
        return subtitles

      } catch {
        cleanup()
        if Task.isCancelled {
          phase = .failed("Operation was cancelled")
          throw OnDeviceTranscribeError.cancelled
        }
        phase = .failed(error.localizedDescription)
        throw error
      }
    }

    currentTask = task
    return try await task.value
  }

  /// Cancels the current operation and cleans up.
  func cancel() {
    currentTask?.cancel()
    currentTask = nil
    cleanup()
    phase = .idle
  }

  /// Resets the view model to idle state.
  func reset() {
    cleanup()
    phase = .idle
    currentTask = nil
  }

  // MARK: - Private Methods

  private func cleanup() {
    // Delete temporary file if exists
    if let url = downloadedFileURL {
      try? FileManager.default.removeItem(at: url)
      downloadedFileURL = nil
    }
  }
}
