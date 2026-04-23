//
//  YouTubeStreamService.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/09.
//

import Foundation
@preconcurrency import YouTubeKit

// MARK: - Stream Selection Strategy

enum StreamSelectionStrategy {
  /// Select highest quality progressive MP4
  case highest
  /// Select lowest quality progressive MP4
  case lowest
  /// Select medium quality progressive MP4
  case medium
  /// Custom selection by resolution
  case resolution(Int)
}

// MARK: - YouTubeStreamService

/// Service for fetching and filtering YouTube video streams.
/// Shared between DownloadView and OnDeviceTranscribeViewModel.
enum YouTubeStreamService {

  // MARK: - Stream Fetching

  /// Fetches all available streams for a video.
  /// - Parameter videoID: YouTube video ID
  /// - Returns: Array of streams sorted by resolution (highest first)
  static func fetchStreams(videoID: YouTubeContentID) async throws -> [YouTubeKit.Stream] {
    let youtube = YouTube(videoID: videoID.rawValue)
    let streams = try await youtube.streams
    return streams.sorted { lhs, rhs in
      (lhs.videoResolution ?? 0) > (rhs.videoResolution ?? 0)
    }
  }

  // MARK: - Stream Filtering

  /// Filters streams to only progressive MP4 (AVPlayer/AVAudioFile compatible).
  /// - Parameter streams: All available streams
  /// - Returns: Filtered progressive MP4 streams
  static func filterProgressiveMP4(_ streams: [YouTubeKit.Stream]) -> [YouTubeKit.Stream] {
    streams.filter { $0.isProgressive && $0.fileExtension == .mp4 }
  }

  // MARK: - Stream Selection

  /// Selects a stream based on the specified strategy.
  /// - Parameters:
  ///   - streams: All available streams (will be filtered to progressive MP4)
  ///   - strategy: Selection strategy
  /// - Returns: Selected stream, or nil if no compatible stream found
  static func selectStream(
    from streams: [YouTubeKit.Stream],
    strategy: StreamSelectionStrategy
  ) -> YouTubeKit.Stream? {
    let progressive = filterProgressiveMP4(streams)
    guard !progressive.isEmpty else { return nil }

    // Sort by resolution (ascending for easier middle selection)
    let sorted: [YouTubeKit.Stream] = progressive.sorted(by: { ($0.videoResolution ?? 0) < ($1.videoResolution ?? 0) })

    switch strategy {
    case .highest:
      return sorted.last

    case .lowest:
      return sorted.first

    case .medium:
      let middleIndex = sorted.count / 2
      return sorted[middleIndex]

    case .resolution(let targetResolution):
      // Find closest match to target resolution
      return sorted.min { lhs, rhs in
        abs((lhs.videoResolution ?? 0) - targetResolution) < abs((rhs.videoResolution ?? 0) - targetResolution)
      }
    }
  }

  /// Convenience method to fetch and select a stream in one call.
  /// - Parameters:
  ///   - videoID: YouTube video ID
  ///   - strategy: Selection strategy
  /// - Returns: Selected stream
  static func fetchAndSelect(
    videoID: YouTubeContentID,
    strategy: StreamSelectionStrategy
  ) async throws -> YouTubeKit.Stream? {
    let streams = try await fetchStreams(videoID: videoID)
    return selectStream(from: streams, strategy: strategy)
  }
}
