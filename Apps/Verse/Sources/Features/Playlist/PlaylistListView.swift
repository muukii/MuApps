//
//  PlaylistListView.swift
//  YouTubeSubtitle
//

import SwiftUI
import SwiftData

struct PlaylistListView: View {
  @Environment(VideoItemService.self) private var historyService
  @Query(sort: \Playlist.updatedAt, order: .reverse) private var playlists: [Playlist]

  @State private var showCreateSheet: Bool = false
  @State private var selectedPlaylist: Playlist?

  var body: some View {
    Group {
      if playlists.isEmpty {
        emptyStateView
      } else {
        listView
      }
    }
    .navigationTitle("Playlists")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showCreateSheet = true
        } label: {
          Label("Add", systemImage: "plus")
        }
      }
    }
    .sheet(isPresented: $showCreateSheet) {
      CreatePlaylistSheet()
    }
    .navigationDestination(item: $selectedPlaylist) { playlist in
      PlaylistDetailView(playlist: playlist)
    }
  }

  // MARK: - Empty State

  private var emptyStateView: some View {
    ContentUnavailableView {
      Label("No Playlists", systemImage: "list.bullet.rectangle")
    } description: {
      Text("Create playlists to organize your videos\nby topic or learning goals.")
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
        PlaylistCell(playlist: playlist)
          .contentShape(Rectangle())
          .onTapGesture {
            selectedPlaylist = playlist
          }
      }
      .onDelete(perform: deletePlaylists)
    }
    .listStyle(.inset)
  }

  // MARK: - Actions

  private func deletePlaylists(at offsets: IndexSet) {
    let playlistsToDelete = offsets.map { playlists[$0] }
    for playlist in playlistsToDelete {
      try? historyService.deletePlaylist(playlist)
    }
  }
}

// MARK: - Playlist Cell

struct PlaylistCell: View {
  let playlist: Playlist

  var body: some View {
    HStack(spacing: 12) {
      // Icon
      Image(systemName: "list.bullet.rectangle.fill")
        .font(.title2)
        .foregroundStyle(.orange)
        .frame(width: 40, height: 40)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))

      // Info
      VStack(alignment: .leading, spacing: 4) {
        Text(playlist.name)
          .font(.headline)

        Text("\(playlist.videoCount) videos")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      // Chevron
      Image(systemName: "chevron.right")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Preview

#Preview {
  NavigationStack {
    PlaylistListView()
  }
}
