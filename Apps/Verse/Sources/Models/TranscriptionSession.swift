//
//  TranscriptionSession.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/14.
//

import Foundation
import SwiftData
import TypedIdentifier

// MARK: - Transcription Session

/// Represents a real-time transcription recording session.
/// Each session contains multiple transcription entries captured during recording.
@Model
final class TranscriptionSession: TypedIdentifiable {

  typealias TypedIdentifierRawValue = UUID

  var typedID: TypedIdentifier<TranscriptionSession> {
    .init(id)
  }

  // MARK: - Core Properties

  var id: UUID

  /// User-defined title for the session (optional)
  var title: String?

  /// Timestamp when the session was created
  var createdAt: Date

  /// Timestamp when the session was last updated
  var updatedAt: Date

  /// Total duration of the session in seconds
  var duration: TimeInterval

  // MARK: - Relationships

  /// All transcription entries in this session (cascade delete)
  @Relationship(deleteRule: .cascade, inverse: \TranscriptionEntry.session)
  var entries: [TranscriptionEntry]

  // MARK: - Computed Properties

  /// Combined plain text of all entries
  var fullText: String {
    entries
      .sorted { $0.timestamp < $1.timestamp }
      .map { $0.text }
      .joined(separator: " ")
  }

  /// Number of entries in this session
  var entryCount: Int {
    entries.count
  }

  /// Display title (user title or auto-generated)
  var displayTitle: String {
    if let title, !title.isEmpty {
      return title
    }
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter.string(from: createdAt)
  }

  // MARK: - Initialization

  init(title: String? = nil) {
    self.id = UUID()
    self.title = title
    self.createdAt = Date()
    self.updatedAt = Date()
    self.duration = 0
    self.entries = []
  }

  // MARK: - Update Helpers

  /// Adds a new entry to this session
  func addEntry(_ entry: TranscriptionEntry) {
    entries.append(entry)
    updatedAt = Date()
  }

  /// Updates the session duration
  func updateDuration(_ newDuration: TimeInterval) {
    duration = newDuration
    updatedAt = Date()
  }
}

// MARK: - Transcription Entry

/// Represents a single transcription segment within a session.
/// Contains the transcribed text and optional word-level timing information.
@Model
final class TranscriptionEntry: TypedIdentifiable {

  typealias TypedIdentifierRawValue = UUID

  var typedID: TypedIdentifier<TranscriptionEntry> {
    .init(id)
  }

  // MARK: - Core Properties

  var id: UUID

  /// The transcribed plain text
  var text: String

  /// Timestamp when this entry was captured
  var timestamp: Date

  /// Word timing data stored as JSON (for playback synchronization)
  var wordTimingsData: Data?

  // MARK: - Relationships

  /// The parent session
  var session: TranscriptionSession?

  // MARK: - Computed Properties

  /// Decoded word timings from stored JSON
  var wordTimings: [Subtitle.WordTiming] {
    get {
      guard let data = wordTimingsData else { return [] }
      return (try? JSONDecoder().decode([Subtitle.WordTiming].self, from: data)) ?? []
    }
    set {
      wordTimingsData = try? JSONEncoder().encode(newValue)
    }
  }

  /// Formatted timestamp for display
  var formattedTime: String {
    let formatter = DateFormatter()
    formatter.timeStyle = .medium
    return formatter.string(from: timestamp)
  }

  // MARK: - Initialization

  init(text: String, timestamp: Date = Date(), wordTimings: [Subtitle.WordTiming] = []) {
    self.id = UUID()
    self.text = text
    self.timestamp = timestamp
    self.wordTimingsData = try? JSONEncoder().encode(wordTimings)
  }
}

// MARK: - TranscriptionDisplayable Conformance

extension TranscriptionEntry: TranscriptionDisplayable {
  var displayText: String { text }
  var displayWordTimings: [Subtitle.WordTiming]? { wordTimings.isEmpty ? nil : wordTimings }
  var displayFormattedTime: String { formattedTime }
}
