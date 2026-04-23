//
//  SubtitleAdapter.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/01.
//

import Foundation
import YoutubeTranscript

/// Adapter for converting between YouTube transcripts and Subtitle format
struct SubtitleAdapter {

  // MARK: - YouTube Transcript -> Subtitle Conversion

  /// Convert YouTube TranscriptResponse array to Subtitle format
  /// Note: YouTube transcripts don't have word-level timing, so wordTimings will be nil
  static func toSubtitle(_ transcripts: [TranscriptResponse]) -> Subtitle {
    let cues = transcripts.enumerated().map { index, transcript in
      Subtitle.Cue(
        id: index + 1,
        startTime: transcript.offset,
        endTime: transcript.offset + transcript.duration,
        text: transcript.text,
        wordTimings: nil  // YouTube doesn't provide word-level timing
      )
    }
    return Subtitle(cues)
  }

  // MARK: - File Format Encoding

  /// Encode subtitles to specified format (srt, vtt)
  static func encode(_ subtitle: Subtitle, format: SubtitleFormat) throws -> String {
    switch format {
    case .srt:
      return encodeSRT(subtitle)
    case .vtt:
      return encodeVTT(subtitle)
    default:
      throw SubtitleError.unsupportedFormat
    }
  }

  private static func encodeSRT(_ subtitle: Subtitle) -> String {
    subtitle.cues.map { cue in
      """
      \(cue.id)
      \(formatSRTTime(cue.startTime)) --> \(formatSRTTime(cue.endTime))
      \(cue.text)
      """
    }.joined(separator: "\n\n")
  }

  private static func encodeVTT(_ subtitle: Subtitle) -> String {
    var result = "WEBVTT\n\n"
    result += subtitle.cues.map { cue in
      """
      \(formatVTTTime(cue.startTime)) --> \(formatVTTTime(cue.endTime))
      \(cue.text)
      """
    }.joined(separator: "\n\n")
    return result
  }

  private static func formatSRTTime(_ seconds: Double) -> String {
    let totalMilliseconds = Int(seconds * 1000)
    let hours = totalMilliseconds / 3_600_000
    let minutes = (totalMilliseconds % 3_600_000) / 60_000
    let secs = (totalMilliseconds % 60_000) / 1000
    let millis = totalMilliseconds % 1000
    return String(format: "%02d:%02d:%02d,%03d", hours, minutes, secs, millis)
  }

  private static func formatVTTTime(_ seconds: Double) -> String {
    let totalMilliseconds = Int(seconds * 1000)
    let hours = totalMilliseconds / 3_600_000
    let minutes = (totalMilliseconds % 3_600_000) / 60_000
    let secs = (totalMilliseconds % 60_000) / 1000
    let millis = totalMilliseconds % 1000
    return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, millis)
  }

  // MARK: - File Format Decoding

  /// Decode subtitles from data with specified format
  static func decode(data: Data, format: SubtitleFormat) throws -> Subtitle {
    guard let content = String(data: data, encoding: .utf8) else {
      throw SubtitleError.invalidEncoding
    }

    switch format {
    case .srt:
      return try decodeSRT(content)
    case .vtt:
      return try decodeVTT(content)
    default:
      throw SubtitleError.unsupportedFormat
    }
  }

  /// Decode subtitles from file URL (auto-detects format from extension)
  static func decode(from url: URL) throws -> Subtitle {
    let data = try Data(contentsOf: url)
    let ext = url.pathExtension.lowercased()

    guard let format = SubtitleFormat.allCases.first(where: { $0.fileExtension == ext }) else {
      throw SubtitleError.unsupportedFormat
    }

    return try decode(data: data, format: format)
  }

  // MARK: - SRT Decoding

  private static func decodeSRT(_ content: String) throws -> Subtitle {
    // Split by double newlines to get blocks
    let blocks = content.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var cues: [Subtitle.Cue] = []

    for block in blocks {
      let lines = block.components(separatedBy: .newlines).filter { !$0.isEmpty }
      guard lines.count >= 3 else { continue }

      // First line is ID
      guard let id = Int(lines[0].trimmingCharacters(in: .whitespaces)) else { continue }

      // Second line is timestamp
      let timeParts = lines[1].components(separatedBy: " --> ")
      guard timeParts.count == 2 else { continue }

      guard let startTime = parseSRTTime(timeParts[0]),
            let endTime = parseSRTTime(timeParts[1]) else { continue }

      // Remaining lines are text
      let text = lines[2...].joined(separator: "\n")

      cues.append(Subtitle.Cue(
        id: id,
        startTime: startTime,
        endTime: endTime,
        text: text,
        wordTimings: nil
      ))
    }

    if cues.isEmpty {
      throw SubtitleError.decodingFailed("No valid cues found in SRT content")
    }

    return Subtitle(cues)
  }

  private static func parseSRTTime(_ timeString: String) -> Double? {
    // Format: HH:MM:SS,mmm or HH:MM:SS.mmm
    let cleaned = timeString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    let parts = cleaned.components(separatedBy: ":")
    guard parts.count == 3 else { return nil }

    guard let hours = Double(parts[0]),
          let minutes = Double(parts[1]),
          let seconds = Double(parts[2]) else { return nil }

    return hours * 3600 + minutes * 60 + seconds
  }

  // MARK: - VTT Decoding

  private static func decodeVTT(_ content: String) throws -> Subtitle {
    // Remove WEBVTT header
    var lines = content.components(separatedBy: .newlines)
    if lines.first?.hasPrefix("WEBVTT") == true {
      lines.removeFirst()
    }

    // Skip any header metadata (lines before first timestamp)
    while !lines.isEmpty && !lines.first!.contains("-->") {
      if lines.first?.isEmpty == true {
        lines.removeFirst()
        break
      }
      lines.removeFirst()
    }

    let remaining = lines.joined(separator: "\n")
    let blocks = remaining.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var cues: [Subtitle.Cue] = []
    var id = 0

    for block in blocks {
      let blockLines = block.components(separatedBy: .newlines).filter { !$0.isEmpty }
      guard !blockLines.isEmpty else { continue }

      // Find timestamp line
      var timestampIndex = 0
      for (index, line) in blockLines.enumerated() {
        if line.contains("-->") {
          timestampIndex = index
          break
        }
      }

      let timeParts = blockLines[timestampIndex].components(separatedBy: " --> ")
      guard timeParts.count >= 2 else { continue }

      // VTT may have settings after the end time
      let endTimePart = timeParts[1].components(separatedBy: " ").first ?? timeParts[1]

      guard let startTime = parseVTTTime(timeParts[0]),
            let endTime = parseVTTTime(endTimePart) else { continue }

      // Text is everything after timestamp
      let textLines = blockLines[(timestampIndex + 1)...]
      let text = textLines.joined(separator: "\n")

      id += 1
      cues.append(Subtitle.Cue(
        id: id,
        startTime: startTime,
        endTime: endTime,
        text: text,
        wordTimings: nil
      ))
    }

    if cues.isEmpty {
      throw SubtitleError.decodingFailed("No valid cues found in VTT content")
    }

    return Subtitle(cues)
  }

  private static func parseVTTTime(_ timeString: String) -> Double? {
    // Format: HH:MM:SS.mmm or MM:SS.mmm
    let cleaned = timeString.trimmingCharacters(in: .whitespaces)
    let parts = cleaned.components(separatedBy: ":")

    switch parts.count {
    case 2:
      // MM:SS.mmm
      guard let minutes = Double(parts[0]),
            let seconds = Double(parts[1]) else { return nil }
      return minutes * 60 + seconds
    case 3:
      // HH:MM:SS.mmm
      guard let hours = Double(parts[0]),
            let minutes = Double(parts[1]),
            let seconds = Double(parts[2]) else { return nil }
      return hours * 3600 + minutes * 60 + seconds
    default:
      return nil
    }
  }
}

// MARK: - Subtitle Format Enum

enum SubtitleFormat: String, CaseIterable, Identifiable {
  case srt = "SubRip"
  case vtt = "WebVTT"
  case sbv = "SubViewer"
  case csv = "CSV"
  case lrc = "Lyrics"
  case ttml = "TTML"

  var id: String { rawValue }

  var fileExtension: String {
    switch self {
    case .srt: return "srt"
    case .vtt: return "vtt"
    case .sbv: return "sbv"
    case .csv: return "csv"
    case .lrc: return "lrc"
    case .ttml: return "ttml"
    }
  }
}

// MARK: - Errors

enum SubtitleError: LocalizedError {
  case invalidEncoding
  case unsupportedFormat
  case decodingFailed(String)

  var errorDescription: String? {
    switch self {
    case .invalidEncoding:
      return "Failed to decode subtitle file with UTF-8 encoding"
    case .unsupportedFormat:
      return "Unsupported subtitle format"
    case .decodingFailed(let message):
      return "Failed to decode subtitle: \(message)"
    }
  }
}
