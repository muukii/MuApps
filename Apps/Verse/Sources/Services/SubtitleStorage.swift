//
//  SubtitleStorage.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/01.
//

import Foundation
import YoutubeTranscript

/// Manager for persisting and loading subtitles
@MainActor
final class SubtitleStorage {

  // MARK: - Singleton

  static let shared = SubtitleStorage()

  private init() {}

  // MARK: - Storage Directories

  private var subtitlesDirectory: URL {
    let subtitlesURL = URL.documentsDirectory.appendingPathComponent("Subtitles", isDirectory: true)

    // Create directory if it doesn't exist
    try? FileManager.default.createDirectory(at: subtitlesURL, withIntermediateDirectories: true)

    return subtitlesURL
  }

  // MARK: - Save Subtitles

  /// Save subtitles for a video with specified format
  func save(
    _ subtitles: Subtitle,
    videoID: YouTubeContentID,
    format: SubtitleFormat
  ) throws {
    let filename = "\(videoID).\(format.fileExtension)"
    let fileURL = subtitlesDirectory.appendingPathComponent(filename)

    let content = try SubtitleAdapter.encode(subtitles, format: format)
    try content.write(to: fileURL, atomically: true, encoding: .utf8)
  }

  /// Save subtitles from YouTube transcripts
  func saveFromYouTube(
    _ transcripts: [TranscriptResponse],
    videoID: YouTubeContentID,
    format: SubtitleFormat
  ) throws {
    let subtitles = SubtitleAdapter.toSubtitle(transcripts)
    try save(subtitles, videoID: videoID, format: format)
  }

  // MARK: - Load Subtitles

  /// Load subtitles for a video with specified format
  func load(videoID: YouTubeContentID, format: SubtitleFormat) throws -> Subtitle {
    let filename = "\(videoID).\(format.fileExtension)"
    let fileURL = subtitlesDirectory.appendingPathComponent(filename)

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      throw StorageError.fileNotFound
    }

    return try SubtitleAdapter.decode(from: fileURL)
  }

  /// Check if subtitles exist for a video
  func exists(videoID: YouTubeContentID, format: SubtitleFormat) -> Bool {
    let filename = "\(videoID).\(format.fileExtension)"
    let fileURL = subtitlesDirectory.appendingPathComponent(filename)
    return FileManager.default.fileExists(atPath: fileURL.path)
  }

  /// List all saved subtitle files for a video
  func listSavedFormats(videoID: YouTubeContentID) -> [SubtitleFormat] {
    SubtitleFormat.allCases.filter { format in
      exists(videoID: videoID, format: format)
    }
  }

  // MARK: - Delete Subtitles

  /// Delete subtitles for a video with specified format
  func delete(videoID: YouTubeContentID, format: SubtitleFormat) throws {
    let filename = "\(videoID).\(format.fileExtension)"
    let fileURL = subtitlesDirectory.appendingPathComponent(filename)

    try FileManager.default.removeItem(at: fileURL)
  }

  /// Delete all subtitles for a video
  func deleteAll(videoID: YouTubeContentID) throws {
    for format in SubtitleFormat.allCases {
      if exists(videoID: videoID, format: format) {
        try? delete(videoID: videoID, format: format)
      }
    }
  }

  // MARK: - Import External Subtitle

  /// Import subtitle file from external source
  func importSubtitle(from url: URL, videoID: YouTubeContentID) throws -> SubtitleFormat {
    // Decode subtitle (auto-detect format from extension)
    let subtitles = try SubtitleAdapter.decode(from: url)

    // Detect format from file extension
    guard let format = SubtitleFormat.allCases.first(where: {
      url.pathExtension.lowercased() == $0.fileExtension
    }) else {
      throw StorageError.unsupportedFormat
    }

    // Save to storage
    try save(subtitles, videoID: videoID, format: format)

    return format
  }

  // MARK: - Export Subtitle

  /// Export subtitle to specified URL
  func export(
    videoID: YouTubeContentID,
    format: SubtitleFormat,
    to destinationURL: URL
  ) throws {
    let subtitles = try load(videoID: videoID, format: format)
    let content = try SubtitleAdapter.encode(subtitles, format: format)
    try content.write(to: destinationURL, atomically: true, encoding: .utf8)
  }

  // MARK: - List All Videos with Subtitles

  /// List all video IDs that have saved subtitles
  func listAllVideoIDs() -> [String] {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: subtitlesDirectory,
      includingPropertiesForKeys: nil
    ) else {
      return []
    }

    let videoIDs = Set(files.compactMap { url -> String? in
      let filename = url.deletingPathExtension().lastPathComponent
      return filename
    })

    return Array(videoIDs).sorted()
  }
}

// MARK: - Storage Error

enum StorageError: LocalizedError {
  case fileNotFound
  case unsupportedFormat
  case saveFailed(String)

  var errorDescription: String? {
    switch self {
    case .fileNotFound:
      return "Subtitle file not found"
    case .unsupportedFormat:
      return "Unsupported subtitle format"
    case .saveFailed(let message):
      return "Failed to save subtitle: \(message)"
    }
  }
}
