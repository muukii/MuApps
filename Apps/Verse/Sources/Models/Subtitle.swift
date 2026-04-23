//
//  Subtitle.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/10.
//

import CoreMedia
import Foundation
import Speech

// MARK: - Subtitle

/// A collection of subtitle cues with support for word-level timing.
nonisolated struct Subtitle: Codable, Equatable, Sendable {
  var cues: [Cue]

  init(_ cues: [Cue] = []) {
    self.cues = cues
  }
}

// MARK: - Cue

extension Subtitle {

  /// A single subtitle cue with timing and optional word-level timing information.
  nonisolated struct Cue: Equatable, Sendable, Identifiable {
    /// Unique identifier for the cue (1-based position)
    let id: Int

    /// Start time in seconds
    let startTime: Double

    /// End time in seconds
    let endTime: Double

    /// The subtitle text content (raw, may contain HTML entities)
    let text: String

    /// Pre-decoded text (HTML entities decoded). Cached for performance.
    let decodedText: String

    /// Word-level timing information (from on-device transcription)
    /// Each WordTiming contains the word text and its precise time range.
    let wordTimings: [WordTiming]?

    init(
      id: Int,
      startTime: Double,
      endTime: Double,
      text: String,
      wordTimings: [WordTiming]? = nil
    ) {
      self.id = id
      self.startTime = startTime
      self.endTime = endTime
      self.text = text
      self.decodedText = text.htmlDecoded
      self.wordTimings = wordTimings
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
      case id, startTime, endTime, text, wordTimings
    }
  }
}

extension Subtitle.Cue: Codable {
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(Int.self, forKey: .id)
    startTime = try container.decode(Double.self, forKey: .startTime)
    endTime = try container.decode(Double.self, forKey: .endTime)
    text = try container.decode(String.self, forKey: .text)
    decodedText = text.htmlDecoded
    wordTimings = try container.decodeIfPresent([Subtitle.WordTiming].self, forKey: .wordTimings)
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(startTime, forKey: .startTime)
    try container.encode(endTime, forKey: .endTime)
    try container.encode(text, forKey: .text)
    try container.encodeIfPresent(wordTimings, forKey: .wordTimings)
  }
}

// MARK: - Cue Computed Properties

extension Subtitle.Cue {

  /// Start time as CMTime
  var startCMTime: CMTime {
    CMTime(seconds: startTime, preferredTimescale: 600)
  }

  /// End time as CMTime
  var endCMTime: CMTime {
    CMTime(seconds: endTime, preferredTimescale: 600)
  }

  /// Whether this cue has word-level timing information
  var hasWordTimings: Bool {
    wordTimings != nil && !(wordTimings?.isEmpty ?? true)
  }
}

// MARK: - WordTiming

extension Subtitle {

  /// Timing information for a single word within a cue.
  nonisolated struct WordTiming: Codable, Equatable, Sendable {
    /// The word text
    let text: String

    /// Start time in seconds
    let startTime: Double

    /// End time in seconds
    let endTime: Double

    init(text: String, startTime: Double, endTime: Double) {
      self.text = text
      self.startTime = startTime
      self.endTime = endTime
    }

    /// Start time as CMTime
    var startCMTime: CMTime {
      CMTime(seconds: startTime, preferredTimescale: 600)
    }

    /// End time as CMTime
    var endCMTime: CMTime {
      CMTime(seconds: endTime, preferredTimescale: 600)
    }

    /// Time range as CMTimeRange
    var timeRange: CMTimeRange {
      CMTimeRange(start: startCMTime, end: endCMTime)
    }
  }
}

// MARK: - Cue Convenience Extensions

extension Subtitle.Cue {

  /// SRT formatted timestamp string (HH:MM:SS,mmm --> HH:MM:SS,mmm)
  var srtTimestamp: String {
    "\(formatSRTTime(startTime)) --> \(formatSRTTime(endTime))"
  }

  /// SRT formatted entry string
  var srtFormat: String {
    """
    \(id)
    \(srtTimestamp)
    \(text)
    """
  }

  private func formatSRTTime(_ seconds: Double) -> String {
    let totalMilliseconds = Int(seconds * 1000)
    let hours = totalMilliseconds / 3_600_000
    let minutes = (totalMilliseconds % 3_600_000) / 60_000
    let secs = (totalMilliseconds % 60_000) / 1000
    let millis = totalMilliseconds % 1000

    return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
  }

  /// Find the word that is currently being spoken at the given time
  func currentWord(at time: CMTime) -> Subtitle.WordTiming? {
    guard let wordTimings else { return nil }
    let seconds = time.seconds
    return wordTimings.first { timing in
      seconds >= timing.startTime && seconds < timing.endTime
    }
  }

  /// Find the range of words that overlap with the given time range
  func wordsInRange(_ range: CMTimeRange) -> [Subtitle.WordTiming] {
    guard let wordTimings else { return [] }
    let rangeStart = range.start.seconds
    let rangeEnd = range.end.seconds
    return wordTimings.filter { timing in
      timing.endTime > rangeStart && timing.startTime < rangeEnd
    }
  }

  /// Creates an AttributedString with audioTimeRange attributes for each word.
  /// This enables word-level highlighting with SelectableSubtitleTextView.
  ///
  /// - Returns: AttributedString with audioTimeRange attributes if wordTimings exist,
  ///            otherwise plain AttributedString from decodedText
  func attributedText() -> AttributedString {
    guard let wordTimings, !wordTimings.isEmpty else {
      // No word timings - return plain text
      return AttributedString(decodedText)
    }

    // Build attributed string with audioTimeRange for each word
    var result = AttributedString()

    for (index, wordTiming) in wordTimings.enumerated() {
      var wordAttr = AttributedString(wordTiming.text)
      wordAttr.audioTimeRange = wordTiming.timeRange
      result.append(wordAttr)

      // Add space between words (except after the last word)
      if index < wordTimings.count - 1 {
        result.append(AttributedString(" "))
      }
    }

    return result
  }
}

// MARK: - Subtitle Export

extension Subtitle {

  /// Export subtitles to SRT format
  func toSRT() -> String {
    cues.map(\.srtFormat).joined(separator: "\n\n")
  }
}
