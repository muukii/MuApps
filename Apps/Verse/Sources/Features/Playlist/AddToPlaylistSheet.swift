//
//  AddToPlaylistSheet.swift
//  YouTubeSubtitle
//

import SwiftUI
import SwiftData

struct AddToPlaylistSheet: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(VideoItemService.self) private var historyService
  @Query(sort: \Playlist.updatedAt, order: .reverse) private var playlists: [Playlist]

  let video: VideoItem

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
      Text("Create a playlist to organize your videos.")
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

            if historyService.isVideo(video, in: playlist) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            }
          }
        }
        .buttonStyle(.plain)
      }
    }
    .listStyle(.inset)
  }

  // MARK: - Actions

  private func addToPlaylist(_ playlist: Playlist) {
    let added = (try? historyService.addVideo(video, to: playlist)) ?? false
    if added {
      dismiss()
    }
    // If already in playlist, stay open (checkmark shows it's already added)
  }
}

// MARK: - Preview

#Preview {
  AddToPlaylistSheet(video: VideoItem(videoID: "test123", url: "https://youtube.com/watch?v=test123"))
}
