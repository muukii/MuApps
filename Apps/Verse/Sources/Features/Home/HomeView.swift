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

struct HomeView: View {
  @Environment(\.modelContext) private var modelContext
  @Environment(VideoItemService.self) private var historyService
  @Environment(DownloadManager.self) private var downloadManager
  @Query(sort: \VideoItem.sortOrder) private var allHistory: [VideoItem]

  @State private var selectedVideoItemID: VideoItem.TypedID?
  @State private var showWebView: Bool = false
  @State private var showSettings: Bool = false
  @State private var showURLInput: Bool = false
  @State private var showMediaImporter: Bool = false
  @State private var isImportingMedia: Bool = false
  @State private var importErrorMessage: String?
  @State private var videoToAddToPlaylist: VideoItem?
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
      allowedContentTypes: [.audio, .movie, .video]
    ) { result in
      handleMediaImport(result)
    }
    .alert(
      "Couldn’t Import File",
      isPresented: Binding(
        get: { importErrorMessage != nil },
        set: { if !$0 { importErrorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(importErrorMessage ?? "An unknown error occurred.")
    }
    .sheet(item: $videoToAddToPlaylist) { video in
      AddToPlaylistSheet(video: video)
    }
    .onChange(of: history.map(\.typedID)) { _, ids in
      if let selectedVideoItemID, !ids.contains(selectedVideoItemID) {
        self.selectedVideoItemID = nil
      }
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
        }
        .safeAreaInset(edge: .bottom) {
          historyActionBar
        }
        .navigationDestination(for: VideoItem.TypedID.self) { id in
          if let item = history.first(where: { $0.typedID == id }) {
            playerDestination(for: item)
          }
        }
    }
  }

  /// Derives the navigation stack path from `selectedVideoItemID`, keeping the
  /// selection as the single source of truth shared with deep links and URL
  /// loading (both of which navigate by setting `selectedVideoItemID`).
  private var navigationPath: Binding<[VideoItem.TypedID]> {
    Binding(
      get: { selectedVideoItemID.map { [$0] } ?? [] },
      set: { selectedVideoItemID = $0.last }
    )
  }

  @ViewBuilder
  private var historyContent: some View {
    if history.isEmpty {
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
      List(selection: $selectedVideoItemID) {
        ForEach(history) { item in
          historyRow(for: item)
        }
        .onDelete { indexSet in
          Task {
            for index in indexSet {
              let item = history[index]
              try? await historyService.deleteHistoryItem(item)
            }
          }
        }
        .onMove { source, destination in
          // Only allow manual reordering in manual sort mode
          guard sortOption == .manual else { return }
          guard let sourceIndex = source.first else { return }
          try? historyService.moveHistoryItem(from: sourceIndex, to: destination)
        }
      }
      .listStyle(.inset)
    }
  }

  private func historyRow(for item: VideoItem) -> some View {
    let isSelected = selectedVideoItemID == item.typedID

    return NavigationLink(value: item.typedID) {
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
    .contextMenu {
      Button {
        videoToAddToPlaylist = item
      } label: {
        Label("Add to Playlist", systemImage: "text.badge.plus")
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
      Button {
        showSettings = true
      } label: {
        Label("Settings", systemImage: "gear")
      }
    }

    ToolbarItem(placement: .topBarTrailing) {
      if !history.isEmpty {
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
      if !history.isEmpty && sortOption == .manual {
        EditButton()
      }
    }
  }

  private var historyActionBar: some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 12) {
        Menu {
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

        Button {
          showWebView = true
        } label: {
          Label("Browse YouTube", systemImage: "safari")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 16)
      .background(.bar)
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

  private func handleMediaImport(_ result: Result<URL, any Error>) {
    switch result {
    case .success(let sourceURL):
      isImportingMedia = true

      Task {
        defer { isImportingMedia = false }

        do {
          selectedVideoItemID = try await historyService.importMedia(from: sourceURL)
        } catch {
          importErrorMessage = error.localizedDescription
        }
      }

    case .failure(let error):
      importErrorMessage = error.localizedDescription
    }
  }
}

#Preview {
  HomeView()
}
