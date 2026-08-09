//
//  PlaylistDetailView.swift
//  YouTubeSubtitle
//

import SwiftUI
import SwiftData

struct PlaylistDetailView: View {
  @Bindable var playlist: Playlist
  @Environment(VideoItemService.self) private var historyService
  @Environment(\.editMode) private var editMode

  @State private var showRenameAlert: Bool = false
  @State private var newName: String = ""

  private var sortedVideos: [VideoItem] {
    playlist.videos
  }

  var body: some View {
    Group {
      if sortedVideos.isEmpty {
        emptyStateView
      } else {
        listView
      }
    }
    .navigationTitle(playlist.name)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        EditButton()
      }
      ToolbarItem(placement: .secondaryAction) {
        Button {
          newName = playlist.name
          showRenameAlert = true
        } label: {
          Label("Rename", systemImage: "pencil")
        }
      }
    }
    .alert("Rename Playlist", isPresented: $showRenameAlert) {
      TextField("Playlist name", text: $newName)
      Button("Cancel", role: .cancel) {}
      Button("Save") {
        if !newName.isEmpty {
          try? historyService.updatePlaylist(playlist, name: newName)
        }
      }
    }
  }

  // MARK: - Empty State

  private var emptyStateView: some View {
    ContentUnavailableView {
      Label("No Videos", systemImage: "film.stack")
    } description: {
      Text("Add videos to this playlist from\nthe video history.")
    }
  }

  // MARK: - List View

  private var listView: some View {
    List {
      ForEach(sortedVideos) { video in
        // Pushes through the enclosing Home stack's HomeRoute destination so
        // the player sits above this playlist in the same navigation path.
        NavigationLink(value: HomeRoute.video(video.typedID)) {
          VideoItemCell(video: video)
        }
        .buttonStyle(.plain)
      }
      .onDelete(perform: deleteVideos)
      .onMove(perform: moveVideos)
    }
    .listStyle(.inset)
  }

  // MARK: - Actions

  private func deleteVideos(at offsets: IndexSet) {
    let videosToRemove = offsets.map { sortedVideos[$0] }
    for video in videosToRemove {
      try? historyService.removeVideo(video, from: playlist)
    }
  }

  private func moveVideos(from source: IndexSet, to destination: Int) {
    try? historyService.reorderVideos(in: playlist, from: source, to: destination)
  }
}

// MARK: - Preview

#Preview {
  NavigationStack {
    PlaylistDetailView(playlist: Playlist(name: "Preview Playlist"))
  }
}
