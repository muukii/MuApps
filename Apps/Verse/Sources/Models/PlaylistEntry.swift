//
//  PlaylistEntry.swift
//  YouTubeSubtitle
//

import Foundation
import SwiftData

// MARK: - Playlist Entry (Join Table)

/// Intermediate entity for many-to-many relationship between Playlist and VideoItem.
/// Stores order and metadata for each video in a playlist.
@Model
final class PlaylistEntry {

  var id: UUID = UUID()

  /// Order of the video in the playlist (0-based)
  var order: Int = 0

  /// When this video was added to the playlist
  var addedAt: Date = Date()

  // MARK: - Relationships

  var playlist: Playlist?
  var video: VideoItem?

  // MARK: - Init

  init(playlist: Playlist, video: VideoItem, order: Int) {
    self.id = UUID()
    self.playlist = playlist
    self.video = video
    self.order = order
    self.addedAt = Date()
  }
}
