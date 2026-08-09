//
//  AddToPlaylistSheet.swift
//  YouTubeSubtitle
//

import SwiftData
import SwiftUI

struct AddToPlaylistSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(VideoItemService.self) private var historyService
  @Query(sort: \Playlist.updatedAt, order: .reverse) private var playlists: [Playlist]

  /// Videos to add, ordered as they should be appended to a playlist.
  let videos: [VideoItem]

  @State private var showCreateSheet: Bool = false

  var body: some View {
    NavigationStack {
      Group {
        if playlists.isEmpty {
          emptyStateView
        } else {
          listView
        }
      }
      .navigationTitle("Add to Playlist")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            showCreateSheet = true
          } label: {
            Label("New", systemImage: "plus")
          }
        }
      }
      .sheet(isPresented: $showCreateSheet) {
        CreatePlaylistSheet()
      }
    }
  }

  // MARK: - Empty State

  private var emptyStateView: some View {
    ContentUnavailableView {
      Label("No Playlists", systemImage: "list.bullet.rectangle")
    } description: {
      Text(
        "\(videos.count) selected. Create a playlist to organize \(videos.count == 1 ? "this video" : "these videos")."
      )
    } actions: {
      Button {
        showCreateSheet = true
      } label: {
        Label("Create Playlist", systemImage: "plus")
      }
      .buttonStyle(.bordered)
    }
  }

  // MARK: - List View

  private var listView: some View {
    List {
      Section {
        ForEach(playlists) { playlist in
          Button {
            addToPlaylist(playlist)
          } label: {
            HStack {
              VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                  .font(.headline)
                  .foregroundStyle(.primary)

                Text("\(playlist.videoCount) videos")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              Spacer()

              if containsAllVideos(in: playlist) {
                Image(systemName: "checkmark.circle.fill")
                  .foregroundStyle(.green)
              }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      } header: {
        Text("\(videos.count) Selected")
      }
    }
    .listStyle(.inset)
  }

  // MARK: - Actions

  private func addToPlaylist(_ playlist: Playlist) {
    let addedCount = (try? historyService.addVideos(videos, to: playlist)) ?? 0
    if addedCount > 0 {
      dismiss()
    }
    // If every video is already present, stay open so the checkmark remains visible.
  }

  private func containsAllVideos(in playlist: Playlist) -> Bool {
    !videos.isEmpty && videos.allSatisfy { historyService.isVideo($0, in: playlist) }
  }
}

// MARK: - Preview

#Preview {
  AddToPlaylistSheet(
    videos: [VideoItem(videoID: "test123", url: "https://youtube.com/watch?v=test123")]
  )
}
