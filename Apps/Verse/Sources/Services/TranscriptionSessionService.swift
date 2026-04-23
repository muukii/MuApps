//
//  TranscriptionSessionService.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/14.
//

import Foundation
import SwiftData

/// Service for managing transcription sessions with CRUD operations.
/// Follows the existing pattern from VocabularyService.
@Observable
@MainActor
final class TranscriptionSessionService {

  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  // MARK: - Create

  /// Create a new transcription session.
  @discardableResult
  func createSession(title: String? = nil) throws -> TranscriptionSession {
    let session = TranscriptionSession(title: title)
    modelContext.insert(session)
    try modelContext.save()
    return session
  }

  /// Add an entry to an existing session.
  @discardableResult
  func addEntry(
    to session: TranscriptionSession,
    text: String,
    timestamp: Date = Date(),
    wordTimings: [Subtitle.WordTiming] = []
  ) throws -> TranscriptionEntry {
    let entry = TranscriptionEntry(
      text: text,
      timestamp: timestamp,
      wordTimings: wordTimings
    )
    entry.session = session
    session.addEntry(entry)
    modelContext.insert(entry)
    try modelContext.save()
    return entry
  }

  // MARK: - Read

  /// Fetch all sessions sorted by creation date (newest first).
  func fetchAll() throws -> [TranscriptionSession] {
    let descriptor = FetchDescriptor<TranscriptionSession>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    return try modelContext.fetch(descriptor)
  }

  /// Fetch sessions with pagination.
  func fetchAll(limit: Int, offset: Int = 0) throws -> [TranscriptionSession] {
    var descriptor = FetchDescriptor<TranscriptionSession>(
      sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
    )
    descriptor.fetchLimit = limit
    descriptor.fetchOffset = offset
    return try modelContext.fetch(descriptor)
  }

  /// Fetch a single session by ID.
  func fetchSession(byID id: UUID) throws -> TranscriptionSession? {
    let descriptor = FetchDescriptor<TranscriptionSession>(
      predicate: #Predicate { $0.id == id }
    )
    return try modelContext.fetch(descriptor).first
  }

  /// Search sessions by title or content.
  func search(query: String) throws -> [TranscriptionSession] {
    guard !query.isEmpty else { return try fetchAll() }

    let lowercaseQuery = query.lowercased()

    // Fetch all sessions and filter in memory
    // (SwiftData doesn't support complex nested predicates well)
    let allSessions = try fetchAll()
    return allSessions.filter { session in
      // Match title
      if let title = session.title?.lowercased(), title.contains(lowercaseQuery) {
        return true
      }
      // Match entry text
      return session.entries.contains { entry in
        entry.text.lowercased().contains(lowercaseQuery)
      }
    }
  }

  /// Get total count of sessions.
  func count() throws -> Int {
    let descriptor = FetchDescriptor<TranscriptionSession>()
    return try modelContext.fetchCount(descriptor)
  }

  // MARK: - Update

  /// Update a session's title.
  func updateTitle(_ session: TranscriptionSession, title: String?) throws {
    session.title = title
    session.updatedAt = Date()
    try modelContext.save()
  }

  /// Update a session's duration.
  func updateDuration(_ session: TranscriptionSession, duration: TimeInterval) throws {
    session.updateDuration(duration)
    try modelContext.save()
  }

  /// Finalize a session (set final duration and save).
  func finalizeSession(_ session: TranscriptionSession, duration: TimeInterval) throws {
    session.updateDuration(duration)
    try modelContext.save()
  }

  // MARK: - Delete

  /// Delete a single session (entries are cascade deleted).
  func deleteSession(_ session: TranscriptionSession) throws {
    modelContext.delete(session)
    try modelContext.save()
  }

  /// Delete multiple sessions.
  func deleteSessions(_ sessions: [TranscriptionSession]) throws {
    for session in sessions {
      modelContext.delete(session)
    }
    try modelContext.save()
  }

  /// Delete all sessions.
  func deleteAll() throws {
    let sessions = try fetchAll()
    for session in sessions {
      modelContext.delete(session)
    }
    try modelContext.save()
  }

  /// Delete a single entry from a session.
  func deleteEntry(_ entry: TranscriptionEntry) throws {
    if let session = entry.session {
      session.updatedAt = Date()
    }
    modelContext.delete(entry)
    try modelContext.save()
  }

  // MARK: - Statistics

  /// Get statistics about transcription sessions.
  func statistics() throws -> SessionStatistics {
    let sessions = try fetchAll()
    let totalDuration = sessions.reduce(0) { $0 + $1.duration }
    let totalEntries = sessions.reduce(0) { $0 + $1.entries.count }

    return SessionStatistics(
      sessionCount: sessions.count,
      totalDuration: totalDuration,
      totalEntries: totalEntries
    )
  }
}

// MARK: - Statistics

extension TranscriptionSessionService {
  struct SessionStatistics: Sendable {
    let sessionCount: Int
    let totalDuration: TimeInterval
    let totalEntries: Int

    var formattedDuration: String {
      let hours = Int(totalDuration) / 3600
      let minutes = (Int(totalDuration) % 3600) / 60
      let seconds = Int(totalDuration) % 60

      if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
      } else {
        return String(format: "%d:%02d", minutes, seconds)
      }
    }
  }
}
