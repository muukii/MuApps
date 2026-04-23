//
//  Playlist.swift
//  YouTubeSubtitle
//

import Foundation
import SwiftData

// MARK: - Playlist

@Model
final class Playlist {

  var id: UUID = UUID()
  var name: String = ""
  var createdAt: Date = Date()
  var updatedAt: Date = Date()

  // MARK: - Relationships

  @Relationship(deleteRule: .cascade, inverse: \PlaylistEntry.playlist)
  var entries: [PlaylistEntry] = []

  // MARK: - Computed Properties

  var videoCount: Int {
    entries.count
  }

  var videos: [VideoItem] {
    entries
      .sorted { $0.order < $1.order }
      .compactMap { $0.video }
  }

  // MARK: - Init

  init(name: String) {
    self.id = UUID()
    self.name = name
    self.createdAt = Date()
    self.updatedAt = Date()
  }
}
