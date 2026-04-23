//
//  VideoItemService.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/06.
//

import Foundation
import SwiftData

/// Service for managing video items and their associated resources.
/// Centralizes operations on VideoItem to ensure proper cleanup of files and data.
@Observable
@MainActor
final class VideoItemService {

  private let modelContext: ModelContext
  private let downloadManager: DownloadManager

  init(modelContext: ModelContext, downloadManager: DownloadManager) {
    self.modelContext = modelContext
    self.downloadManager = downloadManager
  }

  // MARK: - Add to History

  /// Add a video to history with metadata.
  /// Removes any existing entry for the same videoID to prevent duplicates.
  /// New items are inserted at the top of the list.
  func addToHistory(videoID: YouTubeContentID, url: String) async throws {
    // Fetch metadata
    let metadata = await VideoMetadataFetcher.fetch(videoID: videoID)

    // Fetch all history items sorted by sortOrder
    let descriptor = FetchDescriptor<VideoItem>(
      sortBy: [SortDescriptor(\.sortOrder)]
    )
    let history = try modelContext.fetch(descriptor)

    // Remove existing items with same videoID
    let existingItems = history.filter { $0.videoID == videoID }
    for item in existingItems {
      modelContext.delete(item)
    }

    // Calculate sortOrder for new item (insert at top)
    let sortedHistory = history.filter { item in
      item.sortOrder != nil && !existingItems.contains { $0.id == item.id }
    }
    let newSortOrder: String
    if let firstItem = sortedHistory.first, let firstKey = firstItem.sortOrder {
      newSortOrder = LexoRank.before(firstKey)
    } else {
      newSortOrder = LexoRank.initial()
    }

    // Insert new item
    let newItem = VideoItem(
      videoID: videoID,
      url: url,
      title: metadata.title,
      author: metadata.author,
      thumbnailURL: metadata.thumbnailURL
    )
    newItem.sortOrder = newSortOrder
    modelContext.insert(newItem)

    try modelContext.save()
    try checkAndRebalanceIfNeeded()
  }

  // MARK: - Delete History Item

  /// Delete a video item and clean up all associated resources:
  /// - Cancels any active downloads
  /// - Deletes local video file if exists
  /// - Removes from SwiftData
  func deleteHistoryItem(_ item: VideoItem) async throws {
    // 1. Cancel any active downloads
    downloadManager.cancelDownloads(for: item.videoID)

    // 2. Delete local video file if exists
    if let fileURL = item.downloadedFileURL {
      try? FileManager.default.removeItem(at: fileURL)
    }

    // 3. Delete from SwiftData
    modelContext.delete(item)

    try modelContext.save()
  }

  /// Delete multiple video items at once.
  func deleteHistoryItems(_ items: [VideoItem]) async throws {
    for item in items {
      // Cancel downloads and delete files
      downloadManager.cancelDownloads(for: item.videoID)
      if let fileURL = item.downloadedFileURL {
        try? FileManager.default.removeItem(at: fileURL)
      }
      modelContext.delete(item)
    }

    try modelContext.save()
  }

  // MARK: - Clear All History

  /// Clear all video items and their associated resources.
  func clearAllHistory() async throws {
    let descriptor = FetchDescriptor<VideoItem>()
    let allItems = try modelContext.fetch(descriptor)

    try await deleteHistoryItems(allItems)
  }

  // MARK: - Delete Local Video

  /// Delete the local video file for a specific video item.
  /// Updates the downloadedFileName to nil in the database.
  func deleteLocalVideo(for item: VideoItem) throws {
    guard let fileURL = item.downloadedFileURL else { return }

    // Delete the file
    try FileManager.default.removeItem(at: fileURL)

    // Update database
    item.downloadedFileName = nil

    try modelContext.save()
  }

  // MARK: - Update Subtitles

  /// Update cached subtitles for a video.
  func updateCachedSubtitles(videoID: YouTubeContentID, subtitles: Subtitle) throws {
    let videoIDRaw = videoID.rawValue
    let descriptor = FetchDescriptor<VideoItem>(
      predicate: #Predicate { $0._videoID == videoIDRaw }
    )

    guard let item = try modelContext.fetch(descriptor).first else {
      throw VideoItemError.itemNotFound
    }

    item.cachedSubtitles = subtitles

    try modelContext.save()
  }

  // MARK: - Update Playback Position

  /// Update playback position and duration for a video to enable resume functionality.
  /// Also records the last played time.
  /// - Parameters:
  ///   - videoID: The video ID to update
  ///   - position: Current playback position in seconds. Pass nil to clear the position.
  ///   - duration: Total video duration in seconds. Pass nil to keep existing value.
  func updatePlaybackPosition(videoID: YouTubeContentID, position: Double?, duration: Double? = nil) throws {
    let videoIDRaw = videoID.rawValue
    let descriptor = FetchDescriptor<VideoItem>(
      predicate: #Predicate { $0._videoID == videoIDRaw }
    )

    guard let item = try modelContext.fetch(descriptor).first else {
      throw VideoItemError.itemNotFound
    }

    item.lastPlaybackPosition = position
    if let duration {
      item.duration = duration
    }
    item.lastPlayedTime = Date()

    try modelContext.save()
  }

  // MARK: - Find Item

  /// Find a video item by videoID.
  func findItem(videoID: YouTubeContentID) throws -> VideoItem? {
    let videoIDRaw = videoID.rawValue
    let descriptor = FetchDescriptor<VideoItem>(
      predicate: #Predicate { $0._videoID == videoIDRaw }
    )
    return try modelContext.fetch(descriptor).first
  }

  // MARK: - Playlist Management

  /// Create a new playlist with the given name.
  @discardableResult
  func createPlaylist(name: String) throws -> Playlist {
    let playlist = Playlist(name: name)
    modelContext.insert(playlist)
    try modelContext.save()
    return playlist
  }

  /// Update a playlist's name.
  func updatePlaylist(_ playlist: Playlist, name: String) throws {
    playlist.name = name
    playlist.updatedAt = Date()
    try modelContext.save()
  }

  /// Delete a playlist and all its entries.
  func deletePlaylist(_ playlist: Playlist) throws {
    modelContext.delete(playlist)
    try modelContext.save()
  }

  // MARK: - Playlist Entry Management

  /// Add a video to a playlist.
  /// Returns true if added, false if already in playlist.
  @discardableResult
  func addVideo(_ video: VideoItem, to playlist: Playlist) throws -> Bool {
    let isAlreadyInPlaylist = playlist.entries.contains { $0.video?.id == video.id }
    guard !isAlreadyInPlaylist else { return false }

    let order = playlist.entries.count
    let entry = PlaylistEntry(playlist: playlist, video: video, order: order)

    modelContext.insert(entry)
    playlist.updatedAt = Date()
    try modelContext.save()

    return true
  }

  /// Remove a video from a playlist.
  func removeVideo(_ video: VideoItem, from playlist: Playlist) throws {
    guard let entry = playlist.entries.first(where: { $0.video?.id == video.id }) else {
      return
    }

    let removedOrder = entry.order
    modelContext.delete(entry)

    for remainingEntry in playlist.entries where remainingEntry.order > removedOrder {
      remainingEntry.order -= 1
    }

    playlist.updatedAt = Date()
    try modelContext.save()
  }

  /// Reorder videos in a playlist (for drag and drop).
  func reorderVideos(in playlist: Playlist, from source: IndexSet, to destination: Int) throws {
    var entries = playlist.entries.sorted { $0.order < $1.order }

    let itemsToMove = source.map { entries[$0] }

    for index in source.sorted().reversed() {
      entries.remove(at: index)
    }

    let adjustedDestination = destination - source.filter { $0 < destination }.count

    for (offset, item) in itemsToMove.enumerated() {
      entries.insert(item, at: adjustedDestination + offset)
    }

    for (index, entry) in entries.enumerated() {
      entry.order = index
    }

    playlist.updatedAt = Date()
    try modelContext.save()
  }

  /// Check if a video is in a specific playlist.
  func isVideo(_ video: VideoItem, in playlist: Playlist) -> Bool {
    playlist.entries.contains { $0.video?.id == video.id }
  }

  // MARK: - History Ordering

  /// Initialize sort orders for all history items (migration from timestamp-based ordering).
  /// Only initializes items that don't have a sortOrder yet.
  func initializeSortOrders() throws {
    let descriptor = FetchDescriptor<VideoItem>(
      sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
    )
    let items = try modelContext.fetch(descriptor)

    // Check if initialization is needed
    let itemsWithoutOrder = items.filter { $0.sortOrder == nil }
    guard !itemsWithoutOrder.isEmpty else { return }

    // If some items have sortOrder and some don't, only initialize the ones without
    if itemsWithoutOrder.count < items.count {
      // Mixed state: assign orders to items without them, placing at the end
      let itemsWithOrder = items.filter { $0.sortOrder != nil }
        .sorted { ($0.sortOrder ?? "") < ($1.sortOrder ?? "") }

      var lastKey = itemsWithOrder.last?.sortOrder ?? LexoRank.initial()
      for item in itemsWithoutOrder {
        lastKey = LexoRank.after(lastKey)
        item.sortOrder = lastKey
      }
    } else {
      // All items need initialization: distribute evenly
      let keys = LexoRank.distributeKeys(count: items.count)
      for (index, item) in items.enumerated() {
        item.sortOrder = keys[index]
      }
    }

    try modelContext.save()
  }

  /// Move a history item from one position to another (for drag and drop).
  func moveHistoryItem(from sourceIndex: Int, to destinationIndex: Int) throws {
    let descriptor = FetchDescriptor<VideoItem>(
      sortBy: [SortDescriptor(\.sortOrder)]
    )
    var items = try modelContext.fetch(descriptor).filter { $0.sortOrder != nil }

    guard sourceIndex < items.count else { return }
    guard sourceIndex != destinationIndex else { return }

    let movingItem = items[sourceIndex]
    items.remove(at: sourceIndex)

    // Calculate the actual insert index
    let insertIndex: Int
    if destinationIndex > sourceIndex {
      insertIndex = destinationIndex - 1
    } else {
      insertIndex = destinationIndex
    }

    // Determine the keys before and after the insert position
    let beforeItem: VideoItem?
    let afterItem: VideoItem?

    if insertIndex == 0 {
      // Insert at beginning
      beforeItem = nil
      afterItem = items.first
    } else if insertIndex >= items.count {
      // Insert at end
      beforeItem = items.last
      afterItem = nil
    } else {
      // Insert in middle
      beforeItem = items[insertIndex - 1]
      afterItem = items[insertIndex]
    }

    let newKey = LexoRank.between(beforeItem?.sortOrder, afterItem?.sortOrder)
    movingItem.sortOrder = newKey

    try modelContext.save()
    try checkAndRebalanceIfNeeded()
  }

  /// Check if sort order keys need rebalancing and perform it if necessary.
  private func checkAndRebalanceIfNeeded() throws {
    let descriptor = FetchDescriptor<VideoItem>(
      sortBy: [SortDescriptor(\.sortOrder)]
    )
    let items = try modelContext.fetch(descriptor).filter { $0.sortOrder != nil }
    let keys = items.compactMap(\.sortOrder)

    guard LexoRank.needsRebalancing(keys) else { return }

    // Rebalance: assign new evenly distributed keys
    let newKeys = LexoRank.distributeKeys(count: items.count)
    for (index, item) in items.enumerated() {
      item.sortOrder = newKeys[index]
    }

    try modelContext.save()
  }
}

// MARK: - Error

enum VideoItemError: LocalizedError {
  case itemNotFound

  var errorDescription: String? {
    switch self {
    case .itemNotFound:
      return "Video history item not found"
    }
  }
}
