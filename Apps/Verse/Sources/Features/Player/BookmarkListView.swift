//
//  BookmarkListView.swift
//  YouTubeSubtitle
//

import SwiftUI

// MARK: - Bookmark List View

/// List of bookmarked subtitle cues for a video, presented as a sheet from the player.
/// Tapping a bookmark seeks playback to the cue's start time.
///
/// Binding view: owns the SwiftData entity so Observation refreshes the list
/// after insertions/deletions, and maps the content view's ID-based callbacks
/// back to `SubtitleBookmark` instances.
struct BookmarkListView: View {
  let videoItem: VideoItem
  let onSelect: @MainActor @Sendable (SubtitleBookmark) -> Void
  let onDelete: @MainActor @Sendable (SubtitleBookmark) -> Void

  private var bookmarks: [SubtitleBookmark] {
    videoItem.subtitleBookmarks.sorted { $0.startTime < $1.startTime }
  }

  var body: some View {
    let bookmarks = self.bookmarks

    BookmarkListContent(
      rows: bookmarks.map { bookmark in
        BookmarkListContent.Row(
          id: bookmark.id,
          formattedTime: bookmark.formattedStartTime,
          text: bookmark.text
        )
      },
      onSelect: { id in
        if let bookmark = bookmarks.first(where: { $0.id == id }) {
          onSelect(bookmark)
        }
      },
      onDelete: { id in
        if let bookmark = bookmarks.first(where: { $0.id == id }) {
          onDelete(bookmark)
        }
      }
    )
  }
}

// MARK: - Fileprivate Views

/// Stateless content view; constructible with literals for previews and tests.
fileprivate struct BookmarkListContent: View {

  struct Row: Identifiable {
    let id: UUID
    let formattedTime: String
    let text: String
  }

  let rows: [Row]
  let onSelect: @MainActor @Sendable (Row.ID) -> Void
  let onDelete: @MainActor @Sendable (Row.ID) -> Void

  var body: some View {
    Group {
      if rows.isEmpty {
        ContentUnavailableView(
          "No Bookmarks",
          systemImage: "bookmark",
          description: Text("Bookmark subtitles from the row menu or by swiping a subtitle row.")
        )
      } else {
        List {
          ForEach(rows) { row in
            BookmarkRow(
              text: row.text,
              formattedTime: row.formattedTime,
              onTap: { onSelect(row.id) }
            )
          }
          .onDelete { indexSet in
            // Resolve IDs against this body's rows before any deletion mutates
            // the source collection.
            for id in indexSet.map({ rows[$0].id }) {
              onDelete(id)
            }
          }
        }
        .listStyle(.plain)
      }
    }
    .navigationTitle("Bookmarks")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

fileprivate struct BookmarkRow: View {
  let text: String
  let formattedTime: String
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

extension SubtitleBookmark {
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

#Preview("Bookmark List") {
  NavigationStack {
    BookmarkListContent(
      rows: [
        .init(id: UUID(), formattedTime: "0:12", text: "This is a bookmarked subtitle line."),
        .init(id: UUID(), formattedTime: "1:02:45", text: "A bookmark past the one-hour mark with a longer text that wraps across lines."),
      ],
      onSelect: { _ in },
      onDelete: { _ in }
    )
  }
}

#Preview("Empty") {
  NavigationStack {
    BookmarkListContent(
      rows: [],
      onSelect: { _ in },
      onDelete: { _ in }
    )
  }
}
