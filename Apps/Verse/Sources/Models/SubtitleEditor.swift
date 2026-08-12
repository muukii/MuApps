//
//  SubtitleEditor.swift
//  Verse
//

import Foundation

/// Pure operations for reshaping a cached subtitle into user-defined chunks.
///
/// The editor has no UI or persistence dependencies. Every successful edit
/// returns a new `Subtitle` so callers can persist it before replacing visible
/// Player state.
nonisolated enum SubtitleEditor {

  /// The adjacent cue that should be merged into the selected cue.
  enum MergeDirection: Equatable, Sendable {
    case previous
    case next
  }

  /// Failures produced when an edit cannot preserve a valid cue sequence.
  enum EditError: Swift.Error, Equatable, LocalizedError, Sendable {
    case cueNotFound
    case duplicateCueIdentifiers
    case neighborUnavailable
    case invalidSelection
    case splitAtBoundary
    case invalidCueTiming
    case cueIdentifierOverflow

    var errorDescription: String? {
      switch self {
      case .cueNotFound:
        return String(localized: "The subtitle chunk is no longer available.")
      case .duplicateCueIdentifiers:
        return String(localized: "The subtitle file contains duplicate chunk identifiers.")
      case .neighborUnavailable:
        return String(localized: "There is no adjacent subtitle chunk to merge.")
      case .invalidSelection:
        return String(localized: "The selected text is no longer available.")
      case .splitAtBoundary:
        return String(localized: "Select text inside the subtitle chunk to split it.")
      case .invalidCueTiming:
        return String(localized: "The subtitle chunk does not contain a valid time range.")
      case .cueIdentifierOverflow:
        return String(localized: "A new subtitle chunk identifier could not be created.")
      }
    }
  }

  /// Merges a cue with its previous or next neighbor.
  static func merge(
    _ subtitle: Subtitle,
    cueID: Subtitle.Cue.ID,
    direction: MergeDirection,
    editedAt: Date = .now
  ) throws -> Subtitle {
    try validateUniqueCueIdentifiers(in: subtitle)

    guard let selectedIndex = subtitle.cues.firstIndex(where: { $0.id == cueID }) else {
      throw EditError.cueNotFound
    }

    let upperIndex: Int
    let lowerIndex: Int
    switch direction {
    case .previous:
      upperIndex = selectedIndex - 1
      lowerIndex = selectedIndex
    case .next:
      upperIndex = selectedIndex
      lowerIndex = selectedIndex + 1
    }

    guard subtitle.cues.indices.contains(upperIndex),
      subtitle.cues.indices.contains(lowerIndex)
    else {
      throw EditError.neighborUnavailable
    }

    let upperCue = subtitle.cues[upperIndex]
    let lowerCue = subtitle.cues[lowerIndex]
    guard upperCue.startTime < lowerCue.endTime else {
      throw EditError.invalidCueTiming
    }

    let mergedWordTimings: [Subtitle.WordTiming]?
    if let upperWords = upperCue.wordTimings,
      !upperWords.isEmpty,
      let lowerWords = lowerCue.wordTimings,
      !lowerWords.isEmpty
    {
      mergedWordTimings = upperWords + lowerWords
    } else {
      mergedWordTimings = nil
    }

    let mergedText: String
    if let mergedWordTimings {
      mergedText = mergedWordTimings.map(\.text).joined(separator: " ")
    } else {
      mergedText = join(upperCue.decodedText, lowerCue.decodedText)
    }

    let mergedCue = Subtitle.Cue(
      id: upperCue.id,
      startTime: upperCue.startTime,
      endTime: lowerCue.endTime,
      text: mergedText,
      wordTimings: mergedWordTimings
    )

    var cues = subtitle.cues
    cues[upperIndex] = mergedCue
    cues.remove(at: lowerIndex)
    return Subtitle(cues, manuallyEditedAt: editedAt)
  }

  /// Splits a cue at the start of the selected rendered text.
  ///
  /// The selected word begins the lower cue. Timed cues use that word's exact
  /// start time; text-only cues use a proportional estimate within the cue.
  static func split(
    _ subtitle: Subtitle,
    cueID: Subtitle.Cue.ID,
    selection: Subtitle.TextSelection,
    editedAt: Date = .now
  ) throws -> Subtitle {
    try validateUniqueCueIdentifiers(in: subtitle)

    guard let cueIndex = subtitle.cues.firstIndex(where: { $0.id == cueID }) else {
      throw EditError.cueNotFound
    }

    let cue = subtitle.cues[cueIndex]
    guard cue.startTime < cue.endTime else {
      throw EditError.invalidCueTiming
    }

    let newCueID = try nextCueID(in: subtitle)
    let splitCues: (upper: Subtitle.Cue, lower: Subtitle.Cue)
    if let wordTimings = cue.wordTimings, !wordTimings.isEmpty {
      splitCues = try splitTimedCue(
        cue,
        wordTimings: wordTimings,
        selection: selection,
        newCueID: newCueID
      )
    } else {
      splitCues = try splitTextOnlyCue(
        cue,
        selection: selection,
        newCueID: newCueID
      )
    }

    var cues = subtitle.cues
    cues[cueIndex] = splitCues.upper
    cues.insert(splitCues.lower, at: cueIndex + 1)
    return Subtitle(cues, manuallyEditedAt: editedAt)
  }

  // MARK: - Split Helpers

  private static func splitTimedCue(
    _ cue: Subtitle.Cue,
    wordTimings: [Subtitle.WordTiming],
    selection: Subtitle.TextSelection,
    newCueID: Subtitle.Cue.ID
  ) throws -> (upper: Subtitle.Cue, lower: Subtitle.Cue) {
    let displayText = wordTimings.map(\.text).joined(separator: " ")
    try validate(selection, in: displayText)

    var wordRanges: [Range<Int>] = []
    var utf16Offset = 0
    for word in wordTimings {
      let length = word.text.utf16.count
      wordRanges.append(utf16Offset..<(utf16Offset + length))
      utf16Offset += length + 1
    }

    let selectionStart = selection.utf16Range.lowerBound
    guard
      let lowerWordIndex = wordRanges.firstIndex(where: { range in
        range.contains(selectionStart) || range.lowerBound >= selectionStart
      }),
      lowerWordIndex > 0,
      lowerWordIndex < wordTimings.count
    else {
      throw EditError.splitAtBoundary
    }

    let upperWords = Array(wordTimings[..<lowerWordIndex])
    let lowerWords = Array(wordTimings[lowerWordIndex...])
    let splitTime = lowerWords[0].startTime
    guard cue.startTime < splitTime, splitTime < cue.endTime else {
      throw EditError.invalidCueTiming
    }

    let upperCue = Subtitle.Cue(
      id: cue.id,
      startTime: cue.startTime,
      endTime: splitTime,
      text: upperWords.map(\.text).joined(separator: " "),
      wordTimings: upperWords
    )
    let lowerCue = Subtitle.Cue(
      id: newCueID,
      startTime: splitTime,
      endTime: cue.endTime,
      text: lowerWords.map(\.text).joined(separator: " "),
      wordTimings: lowerWords
    )
    return (upperCue, lowerCue)
  }

  private static func splitTextOnlyCue(
    _ cue: Subtitle.Cue,
    selection: Subtitle.TextSelection,
    newCueID: Subtitle.Cue.ID
  ) throws -> (upper: Subtitle.Cue, lower: Subtitle.Cue) {
    let text = cue.decodedText
    let selectedRange = try stringRange(for: selection, in: text)
    let splitIndex = selectedRange.lowerBound
    let upperText = String(text[..<splitIndex])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let lowerText = String(text[splitIndex...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !upperText.isEmpty, !lowerText.isEmpty else {
      throw EditError.splitAtBoundary
    }

    let characterOffset = text.distance(from: text.startIndex, to: splitIndex)
    guard !text.isEmpty else {
      throw EditError.splitAtBoundary
    }
    let ratio = Double(characterOffset) / Double(text.count)
    let splitTime = cue.startTime + ((cue.endTime - cue.startTime) * ratio)
    guard cue.startTime < splitTime, splitTime < cue.endTime else {
      throw EditError.invalidCueTiming
    }

    let upperCue = Subtitle.Cue(
      id: cue.id,
      startTime: cue.startTime,
      endTime: splitTime,
      text: upperText
    )
    let lowerCue = Subtitle.Cue(
      id: newCueID,
      startTime: splitTime,
      endTime: cue.endTime,
      text: lowerText
    )
    return (upperCue, lowerCue)
  }

  // MARK: - Validation Helpers

  private static func validateUniqueCueIdentifiers(in subtitle: Subtitle) throws {
    let identifiers = subtitle.cues.map(\.id)
    guard Set(identifiers).count == identifiers.count else {
      throw EditError.duplicateCueIdentifiers
    }
  }

  private static func nextCueID(in subtitle: Subtitle) throws -> Subtitle.Cue.ID {
    let maximumID = max(subtitle.cues.map(\.id).max() ?? 0, 0)
    let (nextID, overflow) = maximumID.addingReportingOverflow(1)
    guard !overflow else {
      throw EditError.cueIdentifierOverflow
    }
    return nextID
  }

  private static func validate(
    _ selection: Subtitle.TextSelection,
    in text: String
  ) throws {
    _ = try stringRange(for: selection, in: text)
  }

  private static func stringRange(
    for selection: Subtitle.TextSelection,
    in text: String
  ) throws -> Range<String.Index> {
    let utf16Range = selection.utf16Range
    guard !utf16Range.isEmpty,
      utf16Range.lowerBound >= 0,
      utf16Range.upperBound <= text.utf16.count
    else {
      throw EditError.invalidSelection
    }

    let nsRange = NSRange(
      location: utf16Range.lowerBound,
      length: utf16Range.count
    )
    guard let range = Range(nsRange, in: text) else {
      throw EditError.invalidSelection
    }
    guard isCharacterBoundary(range.lowerBound, in: text),
      isCharacterBoundary(range.upperBound, in: text)
    else {
      throw EditError.invalidSelection
    }
    return range
  }

  /// Rejects UTF-16 offsets that fall inside a user-perceived character.
  private static func isCharacterBoundary(
    _ index: String.Index,
    in text: String
  ) -> Bool {
    index == text.endIndex || text.indices.contains(index)
  }

  private static func join(_ upperText: String, _ lowerText: String) -> String {
    let upper = upperText.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = lowerText.trimmingCharacters(in: .whitespacesAndNewlines)
    return [upper, lower].filter { !$0.isEmpty }.joined(separator: " ")
  }
}
