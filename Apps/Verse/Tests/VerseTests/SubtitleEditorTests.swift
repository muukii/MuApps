import Foundation
import Testing

@testable import Verse

@Suite("Subtitle chunk editing")
struct SubtitleEditorTests {
  private let editedAt = Date(timeIntervalSince1970: 1_800_000_000)

  @Test
  func mergingWithPreviousKeepsTheUpperCueIdentity() throws {
    let subtitle = Subtitle([
      cue(id: 10, start: 0, end: 2, text: "First"),
      cue(id: 20, start: 2, end: 4, text: "Second"),
      cue(id: 30, start: 4, end: 6, text: "Third"),
    ])

    let edited = try SubtitleEditor.merge(
      subtitle,
      cueID: 20,
      direction: .previous,
      editedAt: editedAt
    )

    #expect(edited.cues.map(\.id) == [10, 30])
    #expect(edited.cues[0].startTime == 0)
    #expect(edited.cues[0].endTime == 4)
    #expect(edited.cues[0].text == "First Second")
    #expect(edited.manuallyEditedAt == editedAt)
  }

  @Test
  func mergingWithNextKeepsCompleteWordTimings() throws {
    let firstWords = [
      Subtitle.WordTiming(text: "Hello", startTime: 0, endTime: 0.5)
    ]
    let secondWords = [
      Subtitle.WordTiming(text: "world", startTime: 1, endTime: 1.5)
    ]
    let subtitle = Subtitle([
      cue(id: 4, start: 0, end: 1, text: "Hello", wordTimings: firstWords),
      cue(id: 8, start: 1, end: 2, text: "world", wordTimings: secondWords),
    ])

    let edited = try SubtitleEditor.merge(
      subtitle,
      cueID: 4,
      direction: .next,
      editedAt: editedAt
    )

    #expect(edited.cues.count == 1)
    #expect(edited.cues[0].id == 4)
    #expect(edited.cues[0].text == "Hello world")
    #expect(edited.cues[0].wordTimings == firstWords + secondWords)
  }

  @Test
  func mergingAtAnUnavailableBoundaryFails() {
    let subtitle = Subtitle([cue(id: 1, start: 0, end: 2, text: "Only")])

    expectEditError(.neighborUnavailable) {
      try SubtitleEditor.merge(
        subtitle,
        cueID: 1,
        direction: .previous,
        editedAt: editedAt
      )
    }
  }

  @Test
  func timedSplitUsesTheSelectedWordsStartTime() throws {
    let words = [
      Subtitle.WordTiming(text: "I", startTime: 10, endTime: 10.2),
      Subtitle.WordTiming(text: "love", startTime: 10.3, endTime: 10.8),
      Subtitle.WordTiming(text: "café", startTime: 11, endTime: 11.7),
      Subtitle.WordTiming(text: "☕️", startTime: 11.8, endTime: 12.5),
    ]
    let displayText = words.map(\.text).joined(separator: " ")
    let subtitle = Subtitle([
      cue(id: 7, start: 10, end: 13, text: displayText, wordTimings: words)
    ])

    let edited = try SubtitleEditor.split(
      subtitle,
      cueID: 7,
      selection: selection(of: "café", in: displayText),
      editedAt: editedAt
    )

    #expect(edited.cues.map(\.id) == [7, 8])
    #expect(edited.cues[0].text == "I love")
    #expect(edited.cues[0].endTime == 11)
    #expect(edited.cues[0].wordTimings == Array(words.prefix(2)))
    #expect(edited.cues[1].text == "café ☕️")
    #expect(edited.cues[1].startTime == 11)
    #expect(edited.cues[1].wordTimings == Array(words.suffix(2)))
  }

  @Test
  func textOnlySplitConvertsUTF16SelectionToACharacterRatio() throws {
    let text = "Hello 👨‍👩‍👧‍👦 world"
    let subtitle = Subtitle([
      cue(id: 41, start: 10, end: 23, text: text)
    ])

    let edited = try SubtitleEditor.split(
      subtitle,
      cueID: 41,
      selection: selection(of: "world", in: text),
      editedAt: editedAt
    )

    #expect(edited.cues.map(\.id) == [41, 42])
    #expect(edited.cues[0].text == "Hello 👨‍👩‍👧‍👦")
    #expect(edited.cues[1].text == "world")
    #expect(edited.cues[0].endTime == 18)
    #expect(edited.cues[1].startTime == 18)
  }

  @Test
  func splittingAtTheFirstWordFails() {
    let text = "First second"
    let subtitle = Subtitle([cue(id: 1, start: 0, end: 2, text: text)])

    expectEditError(.splitAtBoundary) {
      try SubtitleEditor.split(
        subtitle,
        cueID: 1,
        selection: selection(of: "First", in: text),
        editedAt: editedAt
      )
    }
  }

  @Test
  func selectionThatBisectsAUnicodeScalarFails() {
    let text = "A 😀 B"
    let subtitle = Subtitle([cue(id: 1, start: 0, end: 3, text: text)])

    expectEditError(.invalidSelection) {
      try SubtitleEditor.split(
        subtitle,
        cueID: 1,
        selection: Subtitle.TextSelection(utf16Range: 3..<4),
        editedAt: editedAt
      )
    }
  }

  @Test
  func duplicateCueIdentifiersAreRejected() {
    let subtitle = Subtitle([
      cue(id: 1, start: 0, end: 1, text: "One"),
      cue(id: 1, start: 1, end: 2, text: "Two"),
    ])

    expectEditError(.duplicateCueIdentifiers) {
      try SubtitleEditor.merge(
        subtitle,
        cueID: 1,
        direction: .next,
        editedAt: editedAt
      )
    }
  }

  @Test
  func legacyCachedSubtitleDecodesWithoutManualEditMetadata() throws {
    let data = try #require(#"{"cues":[]}"#.data(using: .utf8))

    let decoded = try JSONDecoder().decode(Subtitle.self, from: data)

    #expect(decoded.manuallyEditedAt == nil)
  }

  @Test
  func transcriptionRevisionRejectsAConcurrentManualEdit() throws {
    let original = Subtitle([
      cue(id: 1, start: 0, end: 1, text: "One"),
      cue(id: 2, start: 1, end: 2, text: "Two"),
    ])
    let revision = Subtitle.RevisionSnapshot(original)
    let edited = try SubtitleEditor.merge(
      original,
      cueID: 1,
      direction: .next,
      editedAt: editedAt
    )

    #expect(revision.matches(original))
    #expect(!revision.matches(edited))
  }

  @Test
  @MainActor
  func srtExportRenumbersEditedCueIdentitiesSequentially() throws {
    let subtitle = Subtitle([
      cue(id: 10, start: 0, end: 1, text: "One"),
      cue(id: 42, start: 1, end: 2, text: "Two"),
    ])

    let modelExport = subtitle.toSRT()
    let adapterExport = try SubtitleAdapter.encode(subtitle, format: .srt)

    #expect(modelExport.hasPrefix("1\n"))
    #expect(modelExport.contains("\n\n2\n"))
    #expect(adapterExport.hasPrefix("1\n"))
    #expect(adapterExport.contains("\n\n2\n"))
  }

  private func cue(
    id: Int,
    start: Double,
    end: Double,
    text: String,
    wordTimings: [Subtitle.WordTiming]? = nil
  ) -> Subtitle.Cue {
    Subtitle.Cue(
      id: id,
      startTime: start,
      endTime: end,
      text: text,
      wordTimings: wordTimings
    )
  }

  private func selection(of selectedText: String, in text: String) -> Subtitle.TextSelection {
    let range = (text as NSString).range(of: selectedText)
    return Subtitle.TextSelection(
      utf16Range: range.location..<(range.location + range.length)
    )
  }

  private func expectEditError(
    _ expectedError: SubtitleEditor.EditError,
    performing edit: () throws -> Subtitle
  ) {
    do {
      _ = try edit()
      Issue.record("Expected subtitle edit to fail with \(expectedError)")
    } catch let error as SubtitleEditor.EditError {
      #expect(error == expectedError)
    } catch {
      Issue.record("Unexpected error: \(error)")
    }
  }
}
