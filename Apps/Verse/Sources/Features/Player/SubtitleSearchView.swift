//
//  SubtitleSearchView.swift
//  YouTubeSubtitle
//

import SwiftUI

// MARK: - Subtitle Search View

/// Full-text search over the current video's subtitle cues, presented as a sheet.
///
/// The query is owned by the presenter so results are retained across
/// presentations. Tapping a result closes the sheet and seeks playback to the
/// cue's start time.
struct SubtitleSearchView: View {
  let cues: [Subtitle.Cue]
  @Binding var query: String
  let onSelect: @MainActor @Sendable (Subtitle.Cue) -> Void

  @FocusState private var isSearchFieldFocused: Bool

  private var trimmedQuery: String {
    query.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Locale-aware search (case- and diacritic-insensitive)
  private var results: [Subtitle.Cue] {
    guard !trimmedQuery.isEmpty else { return [] }
    return cues.filter { $0.decodedText.localizedStandardContains(trimmedQuery) }
  }

  var body: some View {
    VStack(spacing: 0) {
      searchField
      content
    }
    .navigationTitle("Search Subtitles")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .onAppear {
      isSearchFieldFocused = true
    }
  }

  // MARK: - Search Field

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Search subtitles", text: $query)
        .textFieldStyle(.plain)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .focused($isSearchFieldFocused)
        .submitLabel(.search)

      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.quinary, in: RoundedRectangle(cornerRadius: 12))
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if trimmedQuery.isEmpty {
      ContentUnavailableView(
        "Search Subtitles",
        systemImage: "magnifyingglass",
        description: Text("Find a line in this video's subtitles.")
      )
    } else if results.isEmpty {
      ContentUnavailableView.search(text: trimmedQuery)
    } else {
      List {
        Section {
          ForEach(results) { cue in
            SearchResultRow(
              formattedTime: cue.formattedStartTime,
              text: highlightedText(for: cue),
              onTap: { onSelect(cue) }
            )
          }
        } header: {
          Text(resultCountText)
        }
      }
      .listStyle(.plain)
      .scrollDismissesKeyboard(.immediately)
    }
  }

  private var resultCountText: String {
    results.count == 1 ? "1 Match" : "\(results.count) Matches"
  }

  // MARK: - Match Highlighting

  /// Bolds and tints every occurrence of the query within the cue text.
  ///
  /// Uses `localizedStandardRange(of:)` so highlighting shares the exact
  /// matching semantics of the `localizedStandardContains` filter; a manual
  /// options-based search can disagree under locale-specific case folding
  /// (e.g. Turkish dotless i), leaving a matched row with no highlight.
  private func highlightedText(for cue: Subtitle.Cue) -> AttributedString {
    let text = cue.decodedText
    var result = AttributedString()
    var cursor = text.startIndex

    while cursor < text.endIndex,
      let match = text[cursor...].localizedStandardRange(of: trimmedQuery)
    {
      // A diacritic-insensitive query can normalize to an empty match; bail out
      // instead of looping forever.
      guard !match.isEmpty else { break }

      result += AttributedString(String(text[cursor..<match.lowerBound]))

      var highlighted = AttributedString(String(text[match]))
      highlighted.inlinePresentationIntent = .stronglyEmphasized
      highlighted.foregroundColor = .accentColor
      result += highlighted

      cursor = match.upperBound
    }

    result += AttributedString(String(text[cursor...]))
    return result
  }
}

// MARK: - Fileprivate Views

fileprivate struct SearchResultRow: View {
  let formattedTime: String
  let text: AttributedString
  let onTap: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .top, spacing: 12) {
        Text(formattedTime)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(.quinary, in: Capsule())

        Text(text)
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Formatting Helpers

extension Subtitle.Cue {
  fileprivate var formattedStartTime: String {
    let totalSeconds = Int(startTime)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    } else {
      return String(format: "%d:%02d", minutes, seconds)
    }
  }
}

// MARK: - Preview

#Preview("Subtitle Search") {
  @Previewable @State var query = "subtitle"

  NavigationStack {
    SubtitleSearchView(
      cues: [
        Subtitle.Cue(
          id: 1,
          startTime: 12,
          endTime: 15,
          text: "This is a test subtitle."
        ),
        Subtitle.Cue(
          id: 2,
          startTime: 3725,
          endTime: 3729,
          text: "Subtitle search highlights every SUBTITLE match."
        ),
        Subtitle.Cue(
          id: 3,
          startTime: 40,
          endTime: 44,
          text: "This line does not match."
        ),
      ],
      query: $query,
      onSelect: { _ in }
    )
  }
}
