//
//  VideoItemService.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/06.
//

import AVFoundation
import Foundation
import SwiftData
import TypedIdentifier

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

  // MARK: - Import Media

  /// Imports a playable audio or video file into the app's managed storage.
  ///
  /// The picker URL is security-scoped and may become unavailable after the
  /// import callback returns, so this method copies the file into Documents
  /// before creating its history record.
  /// - Parameter sourceURL: A security-scoped URL returned by `fileImporter`.
  /// - Returns: The stable identifier of the inserted history item.
  func importMedia(from sourceURL: URL) async throws -> VideoItem.TypedID {
    guard sourceURL.startAccessingSecurityScopedResource() else {
      throw VideoItemError.fileAccessDenied
    }
    defer { sourceURL.stopAccessingSecurityScopedResource() }

    let preparedMedia = try await Task.detached(priority: .userInitiated) {
      try await Self.prepareImportedMedia(from: sourceURL)
    }.value
    let item = VideoItem(
      videoID: YouTubeContentID(rawValue: "local-\(UUID().uuidString)"),
      url: preparedMedia.storedFileName,
      title: sourceURL.deletingPathExtension().lastPathComponent,
      source: .importedFile,
      importedMediaKind: preparedMedia.kind
    )
    item.downloadedFileName = preparedMedia.storedFileName
    item.duration = preparedMedia.duration
    var didInsertItem = false

    do {
      item.sortOrder = try sortOrderForNewHistoryItem()
      modelContext.insert(item)
      didInsertItem = true
      try modelContext.save()
    } catch {
      if didInsertItem {
        modelContext.delete(item)
      }
      try? FileManager.default.removeItem(at: preparedMedia.storedFileURL)
      throw error
    }

    // Rebalancing is an ordering maintenance operation. The imported item and
    // its file are already committed, so a failure here must not report the
    // otherwise successful import as failed.
    try? checkAndRebalanceIfNeeded()
    return item.typedID
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

  /// Persists a manually edited transcript and reconciles its bookmarks.
  ///
  /// Visible Player state should be replaced only after this method returns.
  /// A save failure rolls the context back so the prior transcript and bookmark
  /// snapshots remain the current persisted state.
  func updateEditedSubtitles(video: VideoItem, subtitles: Subtitle) throws {
    let previousSubtitles = video.cachedSubtitles
    let bookmarkSnapshots = video.subtitleBookmarks.map(SubtitleBookmarkSnapshot.init)

    video.cachedSubtitles = subtitles

    let sortedBookmarks = video.subtitleBookmarks.sorted { lhs, rhs in
      if lhs.createdAt == rhs.createdAt {
        return lhs.id.uuidString < rhs.id.uuidString
      }
      return lhs.createdAt < rhs.createdAt
    }
    var retainedCueIDs: Set<Subtitle.Cue.ID> = []

    for bookmark in sortedBookmarks {
      guard let cue = subtitles.cues.first(where: { bookmark.matches($0) }) else {
        continue
      }

      if retainedCueIDs.insert(cue.id).inserted {
        bookmark.retarget(to: cue)
      } else {
        modelContext.delete(bookmark)
      }
    }

    do {
      try modelContext.save()
    } catch {
      video.cachedSubtitles = previousSubtitles
      for snapshot in bookmarkSnapshots {
        snapshot.restore()
      }
      modelContext.rollback()
      throw error
    }
  }

  // MARK: - Subtitle Bookmarks

  /// Toggle a bookmark for a subtitle cue.
  /// Removes the existing bookmark when the cue is already bookmarked; adds one otherwise.
  func toggleSubtitleBookmark(video: VideoItem, cue: Subtitle.Cue) throws {
    if let existing = video.subtitleBookmarks.first(where: { $0.matches(cue) }) {
      modelContext.delete(existing)
    } else {
      let bookmark = SubtitleBookmark(cue: cue, video: video)
      modelContext.insert(bookmark)
    }

    try modelContext.save()
  }

  /// Delete a subtitle bookmark.
  func deleteSubtitleBookmark(_ bookmark: SubtitleBookmark) throws {
    modelContext.delete(bookmark)
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
    try addVideos([video], to: playlist) == 1
  }

  /// Adds videos to a playlist in input order and saves the batch once.
  ///
  /// Videos already in the playlist and duplicate videos in `videos` are
  /// skipped without changing the relative order of the remaining videos.
  /// - Returns: The number of new playlist entries inserted.
  @discardableResult
  func addVideos(_ videos: [VideoItem], to playlist: Playlist) throws -> Int {
    var knownVideoIDs = Set(playlist.entries.compactMap { $0.video?.id })
    var nextOrder = (playlist.entries.map(\.order).max() ?? -1) + 1
    var addedCount = 0

    for video in videos where knownVideoIDs.insert(video.id).inserted {
      let entry = PlaylistEntry(playlist: playlist, video: video, order: nextOrder)
      modelContext.insert(entry)
      nextOrder += 1
      addedCount += 1
    }

    guard addedCount > 0 else { return 0 }

    playlist.updatedAt = Date()
    try modelContext.save()
    return addedCount
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
    // Heal legacy duplicate keys BEFORE computing the insertion key: between()
    // over a duplicate neighbor pair would place the dropped row outside the
    // pair, and the post-move rebalance would freeze that misplacement.
    try checkAndRebalanceIfNeeded()

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

  /// Returns a key that inserts a new history item at the top of manual order.
  private func sortOrderForNewHistoryItem() throws -> String {
    let descriptor = FetchDescriptor<VideoItem>(
      sortBy: [SortDescriptor(\.sortOrder)]
    )
    let firstKey = try modelContext.fetch(descriptor)
      .compactMap(\.sortOrder)
      .first

    return firstKey.map(LexoRank.before) ?? LexoRank.initial()
  }

  /// Validates and copies a security-scoped media file without occupying the
  /// main actor while potentially large file data is transferred.
  private nonisolated static func prepareImportedMedia(
    from sourceURL: URL
  ) async throws -> PreparedImportedMedia {
    let asset = AVURLAsset(url: sourceURL)
    let tracks = try await asset.load(.tracks)
    let isPlayable = try await asset.load(.isPlayable)
    let hasVideo = tracks.contains { $0.mediaType == .video }
    let hasAudio = tracks.contains { $0.mediaType == .audio }

    guard isPlayable, hasVideo || hasAudio else {
      throw VideoItemError.unsupportedMedia
    }

    let kind: ImportedMediaKind = hasVideo ? .video : .audio
    let duration = try? await asset.load(.duration)
    let durationSeconds = duration.flatMap { duration -> Double? in
      let seconds = duration.seconds
      return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    let pathExtension = sourceURL.pathExtension
    let storedFileName = [
      UUID().uuidString,
      pathExtension.isEmpty ? nil : pathExtension,
    ]
    .compactMap { $0 }
    .joined(separator: ".")
    let storedFileURL = URL.documentsDirectory.appendingPathComponent(storedFileName)

    do {
      try FileManager.default.copyItem(at: sourceURL, to: storedFileURL)
    } catch {
      throw VideoItemError.fileCopyFailed(error)
    }

    return PreparedImportedMedia(
      storedFileName: storedFileName,
      storedFileURL: storedFileURL,
      kind: kind,
      duration: durationSeconds
    )
  }
}

// MARK: - Subtitle Bookmark Snapshot

/// Restorable values used to keep subtitle edits atomic on save failure.
private struct SubtitleBookmarkSnapshot {
  let bookmark: SubtitleBookmark
  let startTime: Double
  let endTime: Double
  let text: String

  init(_ bookmark: SubtitleBookmark) {
    self.bookmark = bookmark
    self.startTime = bookmark.startTime
    self.endTime = bookmark.endTime
    self.text = bookmark.text
  }

  func restore() {
    bookmark.startTime = startTime
    bookmark.endTime = endTime
    bookmark.text = text
  }
}

/// Validated metadata for a file copied into Verse-managed storage.
private nonisolated struct PreparedImportedMedia: Sendable {
  let storedFileName: String
  let storedFileURL: URL
  let kind: ImportedMediaKind
  let duration: Double?
}

// MARK: - Error

nonisolated enum VideoItemError: LocalizedError {
  case itemNotFound
  case fileAccessDenied
  case unsupportedMedia
  case fileCopyFailed(any Error)

  var errorDescription: String? {
    switch self {
    case .itemNotFound:
      return "Video history item not found"
    case .fileAccessDenied:
      return "Verse could not access the selected file."
    case .unsupportedMedia:
      return "The selected file does not contain audio or video that Verse can play."
    case .fileCopyFailed(let error):
      return "Verse could not copy the selected file: \(error.localizedDescription)"
    }
  }
}
