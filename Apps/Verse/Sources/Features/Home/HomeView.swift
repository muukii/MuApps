//
//  HomeView.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/11/30.
//

import SwiftUI
import SwiftData
import TypedIdentifier
import UniformTypeIdentifiers

enum HistorySortOption: String, CaseIterable, Identifiable {
  case manual = "Manual"
  case lastPlayed = "Last Played"
  case dateAdded = "Date Added"

  var id: String { rawValue }

  var systemImage: String {
    switch self {
    case .manual: return "line.3.horizontal"
    case .lastPlayed: return "clock.fill"
    case .dateAdded: return "calendar"
    }
  }
}

/// A pushable destination in the Home navigation stack.
enum HomeRoute: Hashable {
  case video(VideoItem.TypedID)
  case playlist(Playlist)
}

/// A one-shot request to present the playlist picker for an ordered History selection.
private struct PlaylistAdditionRequest: Identifiable {
  let id: UUID = UUID()
  let videos: [VideoItem]
}

struct HomeView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(VideoItemService.self) private var historyService
  @Environment(DownloadManager.self) private var downloadManager
  @Query(sort: \VideoItem.sortOrder) private var allHistory: [VideoItem]
  @Query(sort: \Playlist.updatedAt, order: .reverse) private var playlists: [Playlist]

  @State private var selectedVideoItemID: VideoItem.TypedID?
  @State private var selectedHistoryItemIDs: Set<VideoItem.TypedID> = []
  /// Shared by the List, toolbar, and bottom action bar so every edit surface
  /// transitions from the same explicit source of truth.
  @State private var editMode: EditMode = .inactive
  @State private var selectedPlaylist: Playlist?
  @State private var showWebView: Bool = false
  @State private var showSettings: Bool = false
  @State private var showURLInput: Bool = false
  @State private var showMediaImporter: Bool = false
  @State private var showCreatePlaylistSheet: Bool = false
  @State private var isImportingMedia: Bool = false
  @State private var importErrorMessage: String?
  @State private var playlistAdditionRequest: PlaylistAdditionRequest?
  @State private var isDeleteSelectionConfirmationPresented: Bool = false
  @AppStorage("historySortOption") private var sortOption: HistorySortOption = .manual

  @Namespace private var namespace

  // TODO: Consider moving sorting to SwiftData layer for better performance with large datasets.
  // Current implementation sorts in-memory which may impact performance as history grows.
  // Options: 1) Multiple @Query properties, 2) Manual FetchDescriptor with dynamic sort
  private var history: [VideoItem] {
    switch sortOption {
    case .manual:
      return allHistory
    case .lastPlayed:
      return allHistory.sorted { (item1, item2) in
        // Items with lastPlayedTime come first, sorted by most recent
        switch (item1.lastPlayedTime, item2.lastPlayedTime) {
        case (.some(let date1), .some(let date2)):
          return date1 > date2
        case (.some, .none):
          return true
        case (.none, .some):
          return false
        case (.none, .none):
          // Fall back to timestamp if neither has lastPlayedTime
          return item1.timestamp > item2.timestamp
        }
      }
    case .dateAdded:
      return allHistory.sorted { $0.timestamp > $1.timestamp }
    }
  }

  var body: some View {
    rootLayout
    .sheet(isPresented: $showWebView) {
        NavigationStack {
          YouTubeWebView { videoID in
            Task {
              try? await historyService.addToHistory(
                videoID: videoID,
                url: "https://www.youtube.com/watch?v=\(videoID)"
              )
              // Fetch the VideoItem to navigate to PlayerView
              let videoIDRaw = videoID.rawValue
              let descriptor = FetchDescriptor<VideoItem>(
                predicate: #Predicate { $0._videoID == videoIDRaw }
              )
              if let item = try? modelContext.fetch(descriptor).first {
                selectedVideoItemID = item.typedID
              }
            }
            showWebView = false
          }
          .navigationTitle("YouTube")
          #if os(iOS)
          .navigationBarTitleDisplayMode(.inline)
          #endif
          .toolbar {
            ToolbarItem(placement: .cancellationAction) {
              Button("Close") {
                showWebView = false
              }
            }
          }
        }
    }
    .sheet(isPresented: $showSettings) {
      SettingsView()
        .environment(historyService)
    }
    .fittingSheet(isPresented: $showURLInput) {
      URLInputSheet { urlText in
        loadURL(urlText)
      }
    }
    .fileImporter(
      isPresented: $showMediaImporter,
      allowedContentTypes: [.audio, .movie, .video],
      allowsMultipleSelection: true
    ) { result in
      handleMediaImport(result)
    }
    .alert(
      "Couldn’t Import Media",
      isPresented: Binding(
        get: { importErrorMessage != nil },
        set: { if !$0 { importErrorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(importErrorMessage ?? "An unknown error occurred.")
    }
    .confirmationDialog(
      "Delete Selected Videos?",
      isPresented: $isDeleteSelectionConfirmationPresented,
      titleVisibility: .visible
    ) {
      if selectedHistoryItemIDs.count == 1 {
        Button("Delete Video", role: .destructive) {
          deleteSelectedHistoryItems()
        }
      } else {
        Button("Delete \(selectedHistoryItemIDs.count) Videos", role: .destructive) {
          deleteSelectedHistoryItems()
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently removes the selected videos and their downloaded files.")
    }
    .sheet(item: $playlistAdditionRequest) { request in
      AddToPlaylistSheet(videos: request.videos)
    }
    .sheet(isPresented: $showCreatePlaylistSheet) {
      CreatePlaylistSheet()
    }
    .onChange(of: history.map(\.typedID)) { _, ids in
      if let selectedVideoItemID, !ids.contains(selectedVideoItemID) {
        self.selectedVideoItemID = nil
      }
      selectedHistoryItemIDs.formIntersection(Set(ids))
      if ids.isEmpty {
        editMode = .inactive
      }
    }
    .onChange(of: editMode) { _, editMode in
      guard !editMode.isEditing else { return }
      selectedHistoryItemIDs.removeAll()
    }
    .task {
      // Initialize sort orders for existing items (migration)
      try? historyService.initializeSortOrders()
    }
  }

  private var rootLayout: some View {
    NavigationStack(path: navigationPath) {
      historyContent
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          topToolbarContent
          
          bottomToolbarContent
        }
        .navigationDestination(for: HomeRoute.self) { route in
          switch route {
          case .video(let id):
            if let item = history.first(where: { $0.typedID == id }) {
              playerDestination(for: item)
            }
          case .playlist(let playlist):
            PlaylistDetailView(playlist: playlist)
          }
        }
    }
  }

  /// Derives the navigation stack path from the selection states, keeping them
  /// as the single source of truth shared with deep links and URL loading
  /// (both of which navigate by setting `selectedVideoItemID`).
  ///
  /// A video route always sits above the playlist route it was opened from, so
  /// the stack is at most `[.playlist, .video]`.
  private var navigationPath: Binding<[HomeRoute]> {
    Binding(
      get: {
        var path: [HomeRoute] = []
        if let selectedPlaylist {
          path.append(.playlist(selectedPlaylist))
        }
        if let selectedVideoItemID {
          path.append(.video(selectedVideoItemID))
        }
        return path
      },
      set: { path in
        selectedPlaylist = path.lazy
          .compactMap { route -> Playlist? in
            switch route {
            case .playlist(let playlist): return playlist
            case .video: return nil
            }
          }
          .first
        selectedVideoItemID = path.reversed().lazy
          .compactMap { route -> VideoItem.TypedID? in
            switch route {
            case .video(let id): return id
            case .playlist: return nil
            }
          }
          .first
      }
    )
  }

  @ViewBuilder
  private var historyContent: some View {
    if history.isEmpty && playlists.isEmpty {
      ContentUnavailableView {
        Label("Verse", systemImage: "captions.bubble.fill")
      } description: {
        Text("Watch YouTube videos or files with synced subtitles.\nAdd a URL, import audio or video, or browse YouTube to get started.")
      } actions: {
        Button {
          loadDemoVideo()
        } label: {
          Label("Try Demo Video", systemImage: "play.circle")
        }
        .buttonStyle(.bordered)
      }
    } else {
      List(selection: $selectedHistoryItemIDs) {
        playlistsSection

        if !history.isEmpty {
          historySection
        }
      }
      .contextMenu(forSelectionType: VideoItem.TypedID.self) { selectedIDs in
        if !selectedIDs.isEmpty {
          Button {
            presentAddToPlaylist(for: selectedIDs)
          } label: {
            if selectedIDs.count == 1 {
              Label("Add to Playlist", systemImage: "text.badge.plus")
            } else {
              Label(
                "Add \(selectedIDs.count) Videos to Playlist",
                systemImage: "text.badge.plus"
              )
            }
          }
        }
      }
      .environment(\.editMode, $editMode)
      .listStyle(.inset)
    }
  }

  private var playlistsSection: some View {
    Section {
      ScrollView(.horizontal) {
        HStack(spacing: 12) {
          ForEach(playlists) { playlist in
            NavigationLink(value: HomeRoute.playlist(playlist)) {
              PlaylistCard(name: playlist.name, videoCount: playlist.videoCount)
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button(role: .destructive) {
                try? historyService.deletePlaylist(playlist)
              } label: {
                Label("Delete Playlist", systemImage: "trash")
              }
            }
          }

          Button {
            showCreatePlaylistSheet = true
          } label: {
            NewPlaylistCard()
          }
          .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
      }
      .scrollIndicators(.hidden)
      .listRowInsets(EdgeInsets())
      .listRowSeparator(.hidden)
      .listRowBackground(Color.clear)
    } header: {
      Text("Playlists")
        .padding(.leading, 4)
    }
  }

  private var historySection: some View {
    Section {
      ForEach(history) { item in
        historyRow(for: item)
      }
      .onMove(perform: historyMoveAction)
    } header: {
      Text("History")
        .padding(.leading, 4)
    }
  }

  private func historyRow(for item: VideoItem) -> some View {
    let isSelected = selectedVideoItemID == item.typedID

    return NavigationLink(value: HomeRoute.video(item.typedID)) {
      VideoItemCell(
        video: item,
        namespace: namespace,
        downloadManager: downloadManager,
        showTimestamp: true
      )
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
          .overlay {
            if isSelected {
              RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
            }
          }
      }
      .matchedTransitionSource(id: item.videoID, in: namespace)
    }
    .tag(item.typedID)
    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
      Button(role: .destructive) {
        Task {
          try? await historyService.deleteHistoryItem(item)
        }
      } label: {
        Label("Delete", systemImage: "trash")
      }
    }
    .listRowInsets(
      EdgeInsets(
        top: 4,
        leading: 0,
        bottom: 4,
        trailing: 0
      )
    )
    .listRowSeparator(.hidden)
    .listRowBackground(Color.clear)
  }

  @ToolbarContentBuilder
  private var topToolbarContent: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      if editMode.isEditing {
        Button {
          if isAllHistorySelected {
            selectedHistoryItemIDs.removeAll()
          } else {
            selectedHistoryItemIDs = Set(history.map(\.typedID))
          }
        } label: {
          if isAllHistorySelected {
            Text("Deselect All")
          } else {
            Text("Select All")
          }
        }
      } else {
        Button {
          showSettings = true
        } label: {
          Label("Settings", systemImage: "gear")
        }
      }
    }

    ToolbarItem(placement: .topBarTrailing) {
      if !history.isEmpty && !editMode.isEditing {
        Menu {
          Picker("Sort by", selection: $sortOption) {
            ForEach(HistorySortOption.allCases) { option in
              Label(option.rawValue, systemImage: option.systemImage)
                .tag(option)
            }
          }
          .pickerStyle(.inline)
        } label: {
          Label("Sort", systemImage: sortOption.systemImage)
        }
      }
    }

    ToolbarItem(placement: .primaryAction) {
      if !history.isEmpty {
        Button(editMode.isEditing ? "Done" : "Edit") {
          withAnimation {
            editMode = editMode.isEditing ? .inactive : .active
          }
        }
      }
    }
  }
  
  @ToolbarContentBuilder
  private var bottomToolbarContent: some ToolbarContent {    
    if editMode.isEditing {
      ToolbarItem(placement: .bottomBar) { 
        Button {
          presentAddToPlaylist(for: selectedHistoryItemIDs)
        } label: {
          Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        .buttonStyle(.bordered)
        .disabled(selectedHistoryItemIDs.isEmpty)
      }

      ToolbarItem(placement: .bottomBar) { 
        Button {
          isDeleteSelectionConfirmationPresented = true
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(selectedHistoryItemIDs.isEmpty)
      }
    } else {
      ToolbarItem(placement: .bottomBar) { 
        Menu {
          
          Button {
            showWebView = true
          } label: {
            Label("Browse YouTube", systemImage: "safari")
              .frame(maxWidth: .infinity)
          }
          .buttonStyle(.bordered)
          
          Button {
            showURLInput = true
          } label: {
            Label("Paste YouTube URL", systemImage: "link")
          }

          Button {
            showMediaImporter = true
          } label: {
            Label("Import Audio or Video", systemImage: "folder")
          }
          
        } label: {
          if isImportingMedia {
            HStack {
              ProgressView()
              Text("Importing...")
            }
            .frame(maxWidth: .infinity)
          } else {
            Label("Add Media", systemImage: "plus")
              .frame(maxWidth: .infinity)
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isImportingMedia)
      
      }
    }
  }

  private var isAllHistorySelected: Bool {
    !history.isEmpty && selectedHistoryItemIDs.count == history.count
  }

  private var historyMoveAction: ((IndexSet, Int) -> Void)? {
    guard sortOption.supportsManualReordering else { return nil }
    return moveHistoryItems
  }

  private var historySelectionActionBar: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 12) {
        Text("\(selectedHistoryItemIDs.count) Selected")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        Spacer()

        Button {
          presentAddToPlaylist(for: selectedHistoryItemIDs)
        } label: {
          Label("Add to Playlist", systemImage: "text.badge.plus")
        }
        .buttonStyle(.bordered)
        .disabled(selectedHistoryItemIDs.isEmpty)

        Button {
          isDeleteSelectionConfirmationPresented = true
        } label: {
          Label("Delete", systemImage: "trash")
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .disabled(selectedHistoryItemIDs.isEmpty)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      .background(.bar)
    }
  }

  private var historyActionBar: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 12) {
       
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 16)
      .background(.bar)
    }
  }

  private func moveHistoryItems(from source: IndexSet, to destination: Int) {
    guard let sourceIndex = source.first else { return }
    try? historyService.moveHistoryItem(from: sourceIndex, to: destination)
  }

  private func presentAddToPlaylist(for selectedIDs: Set<VideoItem.TypedID>) {
    let selectedVideos = history.filter { selectedIDs.contains($0.typedID) }
    guard !selectedVideos.isEmpty else { return }

    playlistAdditionRequest = PlaylistAdditionRequest(videos: selectedVideos)
  }

  private func deleteSelectedHistoryItems() {
    let selectedIDs = selectedHistoryItemIDs
    let selectedItems = history.filter { selectedIDs.contains($0.typedID) }
    guard !selectedItems.isEmpty else { return }

    selectedHistoryItemIDs.removeAll()
    Task {
      try? await historyService.deleteHistoryItems(selectedItems)
    }
  }

  private func playerDestination(for videoItem: VideoItem) -> some View {
    PlayerView(videoItem: videoItem)
      .id(videoItem.videoID.rawValue)
      .navigationTransition(.zoom(sourceID: videoItem.videoID, in: namespace))
  }
  
  private func loadURL(_ urlText: String) {
    guard let url = URL(string: urlText), !urlText.isEmpty else {
      return
    }

    // Extract video ID and navigate to player
    if let videoID = YouTubeURLParser.extractVideoID(from: url) {
      Task {
        try? await historyService.addToHistory(videoID: videoID, url: urlText)
        // Fetch the VideoItem to navigate to PlayerView
        let videoIDRaw = videoID.rawValue
        let descriptor = FetchDescriptor<VideoItem>(
          predicate: #Predicate { $0._videoID == videoIDRaw }
        )
        if let item = try? modelContext.fetch(descriptor).first {
          await MainActor.run {
            selectedVideoItemID = item.typedID
          }
        }
      }
    }
  }

  private func loadDemoVideo() {
    let demoVideoID: YouTubeContentID = "JKpsGXPqMd8"
    let demoURL = "https://www.youtube.com/watch?v=\(demoVideoID)"
    Task {
      try? await historyService.addToHistory(videoID: demoVideoID, url: demoURL)
      // Fetch the VideoItem to navigate to PlayerView
      let videoIDRaw = demoVideoID.rawValue
      let descriptor = FetchDescriptor<VideoItem>(
        predicate: #Predicate { $0._videoID == videoIDRaw }
      )
      if let item = try? modelContext.fetch(descriptor).first {
        await MainActor.run {
          selectedVideoItemID = item.typedID
        }
      }
    }
  }

  private func handleMediaImport(_ result: Result<[URL], any Error>) {
    switch result {
    case .success(let sourceURLs):
      isImportingMedia = true

      Task {
        defer { isImportingMedia = false }

        var importedItemIDs: [VideoItem.TypedID] = []
        var failureDescriptions: [String] = []

        // The picker's URL order is arbitrary, so sort by filename for a
        // predictable result. Each import inserts its item at the top of the
        // list, so importing in reverse keeps the final top-to-bottom order
        // matching the sorted order.
        let orderedURLs = sourceURLs.sorted {
          $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        for sourceURL in orderedURLs.reversed() {
          do {
            importedItemIDs.append(try await historyService.importMedia(from: sourceURL))
          } catch {
            failureDescriptions.append("\(sourceURL.lastPathComponent): \(error.localizedDescription)")
          }
        }

        // A single imported file opens the player directly; a batch import
        // stays on the list so every new item is visible.
        if importedItemIDs.count == 1 {
          selectedVideoItemID = importedItemIDs[0]
        }

        if !failureDescriptions.isEmpty {
          importErrorMessage = failureDescriptions.joined(separator: "\n")
        }
      }

    case .failure(let error):
      importErrorMessage = error.localizedDescription
    }
  }
}

extension HistorySortOption {
  /// Whether Home edit mode should expose drag handles for this ordering.
  fileprivate var supportsManualReordering: Bool {
    switch self {
    case .manual:
      true
    case .lastPlayed, .dateAdded:
      false
    }
  }
}

// MARK: - Playlist Shelf Cards

fileprivate struct PlaylistCard: View {
  let name: String
  let videoCount: Int

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Image(systemName: "list.bullet.rectangle.fill")
        .font(.title3)
        .foregroundStyle(.orange)
        .frame(width: 36, height: 36)
        .background(Color.orange.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

      Spacer(minLength: 4)

      Text(name)
        .font(.subheadline.weight(.semibold))
        .lineLimit(2)
        .multilineTextAlignment(.leading)

      Text("\(videoCount) videos")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(width: 150, height: 116, alignment: .topLeading)
    .background(Color(.secondarySystemBackground))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

fileprivate struct NewPlaylistCard: View {
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: "plus")
        .font(.title3.weight(.semibold))

      Text("New Playlist")
        .font(.subheadline.weight(.semibold))
    }
    .foregroundStyle(.secondary)
    .frame(width: 150, height: 116)
    .background {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
        .foregroundStyle(.tertiary)
    }
    // The dashed border renders no interior pixels, so without an explicit
    // shape only the icon/text cluster and the stroke would be tappable.
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

#Preview {
  HomeView()
}

#Preview("PlaylistCard") {
  HStack(spacing: 12) {
    PlaylistCard(name: "English Listening Practice", videoCount: 12)
    NewPlaylistCard()
  }
  .padding()
}
