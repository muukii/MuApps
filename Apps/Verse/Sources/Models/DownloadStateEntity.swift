//
//  DownloadStateEntity.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/12/06.
//

import Foundation
import SwiftData
import TypedIdentifier

/// Represents an active download state.
/// This entity exists only during download (pending or downloading).
/// When download completes, fails, or is cancelled, this entity is deleted.
@Model
final class DownloadStateEntity: TypedIdentifiable {

  typealias TypedIdentifierRawValue = UUID

  var typedID: TypedIdentifier<DownloadStateEntity> {
    .init(id)
  }

  var id: UUID

  /// Stream URL for downloading
  var streamURL: String

  /// File extension (mp4, webm, etc.)
  var fileExtension: String

  /// Status: "pending" or "downloading"
  var statusRawValue: String

  /// Inverse relationship to VideoItem
  var videoItem: VideoItem?

  // MARK: - Status Enum

  enum Status: String {
    case pending
    case downloading
  }

  var status: Status {
    get { Status(rawValue: statusRawValue) ?? .pending }
    set { statusRawValue = newValue.rawValue }
  }

  // MARK: - Initialization

  init(streamURL: String, fileExtension: String) {
    self.id = UUID()
    self.streamURL = streamURL
    self.fileExtension = fileExtension
    self.statusRawValue = Status.pending.rawValue
  }
}
