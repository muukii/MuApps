//
//  SubtitleBookmark.swift
//  YouTubeSubtitle
//

import Foundation
import SwiftData

// MARK: - Subtitle Bookmark

/// A bookmarked subtitle cue within a video.
///
/// Stores a snapshot of the cue's text and timing so the bookmark stays
/// meaningful even if the transcript is later regenerated. Matching against
/// the currently loaded transcript uses `startTime`, which is time-anchored
/// and safer than positional cue IDs across re-transcriptions.
@Model
final class SubtitleBookmark {

  var id: UUID = UUID()

  /// Start time of the bookmarked cue in seconds.
  var startTime: Double = 0

  /// End time of the bookmarked cue in seconds.
  var endTime: Double = 0

  /// Decoded text snapshot of the bookmarked cue.
  var text: String = ""

  var createdAt: Date = Date()

  // MARK: - Relationships

  var video: VideoItem?

  // MARK: - Init

  init(cue: Subtitle.Cue, video: VideoItem) {
    self.id = UUID()
    self.startTime = cue.startTime
    self.endTime = cue.endTime
    self.text = cue.decodedText
    self.createdAt = Date()
    self.video = video
  }
}

// MARK: - Cue Matching

extension SubtitleBookmark {

  /// Whether this bookmark refers to the given cue.
  ///
  /// Matches by containment of the bookmarked cue's temporal midpoint rather
  /// than exact start-time equality: auto re-transcription replaces cues with
  /// slightly shifted timings and different segmentation, and an exact match
  /// would silently detach the bookmark from its row (and let the toggle
  /// insert near-duplicates).
  func matches(_ cue: Subtitle.Cue) -> Bool {
    let midpoint = (startTime + endTime) / 2
    return cue.startTime <= midpoint && midpoint < cue.endTime
  }
}
